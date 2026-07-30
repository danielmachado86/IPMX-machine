#!/usr/bin/env python3
"""Receives IPMX RTCP Sender Reports and decodes the Info Block against the TR tables.

Written from the specification tables rather than from the Swift encoder, on purpose: checking
a serializer with its own parser lets a shared misreading pass unnoticed.

Decodes:
  - RTCP Sender Report                    RFC 3550 §6.4.1, TR-10-1 §8.7
  - IPMX Info Block, tag 0x5831           TR-10-1 §8.7
  - Media Info Block 0x0005, video        TR-10-7 §12 + TR-10-2 §10
  - Media Info Block 0x000A, H.264        TR-10-15 Part 3 §16
  - Media Info Block 0x0009, H.265        TR-10-15 Part 2 §16

Usage:
    scripts/rtcp-monitor.py --group 127.0.0.1 --port 50001 --count 5
    scripts/rtcp-monitor.py --group 239.10.10.10 --port 50001 --iface 192.168.1.50
"""

import argparse
import socket
import struct
import sys
import time

SR_PAYLOAD_TYPE = 200
IPMX_TAG = 0x5831
INFO_BLOCK_HEADER_BYTES = 84


def text(raw: bytes) -> str:
    return raw.split(b"\x00", 1)[0].decode("ascii", "replace")


def decode_video_block(content: bytes) -> list[str]:
    """TR-10-2 §10 layout, reused by TR-10-7 §12 with the type changed to 0x0005."""
    if len(content) < 88:
        return [f"  truncated video block ({len(content)} bytes, expected 88)"]

    sampling = text(content[0:16])
    packed = struct.unpack(">I", content[16:20])[0]
    floating = (packed >> 31) & 1
    bit_depth = (packed >> 24) & 0x7F
    packing = (packed >> 23) & 1
    interlaced = (packed >> 22) & 1
    segmented = (packed >> 21) & 1
    par_w = (packed >> 8) & 0xFF
    par_h = packed & 0xFF

    rng = text(content[20:32])
    colorimetry = text(content[32:52])
    tcs = text(content[52:68])
    width, height = struct.unpack(">HH", content[68:72])
    rate = struct.unpack(">I", content[72:76])[0]
    rate_num, rate_den = rate >> 10, rate & 0x3FF
    pixel_clock = struct.unpack(">Q", content[76:84])[0]
    htotal, vtotal = struct.unpack(">HH", content[84:88])

    lines = [
        f"  sampling={sampling} depth={bit_depth} float={floating} packing={'general' if packing else 'block'}",
        f"  interlaced={interlaced} segmented={segmented} PAR={par_w}:{par_h}",
        f"  range={rng} colorimetry={colorimetry} TCS={tcs}",
        f"  {width}x{height} @ {rate_num}/{rate_den} fps",
        f"  measuredpixclk={pixel_clock} htotal={htotal} vtotal={vtotal}",
    ]
    # TR-10-9 §10 for a sender that cannot measure blanking.
    if htotal == width and vtotal == height:
        expected = width * height * (rate_num // max(rate_den, 1))
        ok = "ok" if pixel_clock == expected else f"MISMATCH, expected {expected}"
        lines.append(f"  non-baseband per TR-10-9 §10: htotal=width, vtotal=height, pixclk {ok}")
    return lines


H264_FIELDS = ["profile-level-id", "packetization-mode", "sprop-max-don-diff",
               "sprop-interleaving-depth", "sprop-deint-buf-req", "sprop-init-buf-time",
               "sprop-parameter-sets", "sprop-level-parameter-sets", "extra"]


def decode_h264_block(content: bytes) -> list[str]:
    """TR-10-15 Part 3 §16. The fixed part is 28 bytes including the 4-byte block header."""
    if len(content) < 24:
        return [f"  truncated H.264 block ({len(content)} bytes)"]

    mask = struct.unpack(">I", content[0:4])[0]
    present = [name for index, name in enumerate(H264_FIELDS) if mask & (1 << index)]
    profile_level_id = content[4:7].hex().upper()
    packetization_mode = content[7]
    param_sets_n, l_param_sets_n, extra_n = content[20], content[21], content[22]

    lines = [
        f"  FIELD-PRESENT-MASK=0x{mask:08X} -> {', '.join(present) or 'nothing'}",
        f"  profile-level-id={profile_level_id} packetization-mode={packetization_mode}",
    ]
    tail = content[24:]
    if param_sets_n:
        lines.append(f"  sprop-parameter-sets={text(tail[:param_sets_n])}")
    if l_param_sets_n:
        lines.append(f"  sprop-level-parameter-sets={text(tail[param_sets_n:param_sets_n + l_param_sets_n])}")
    if extra_n:
        lines.append(f"  extra={extra_n} bytes")
    return lines


H265_FIELDS = ["profile-space", "profile-id", "level-id", "tier-flag",
               "profile-compatibility-indicator", "interop-constraints", "sprop-max-don-diff",
               "tx-mode", "sprop-depack-buf-bytes", "sprop-depack-buf-nalus",
               "sprop-spatial-segmentation-idc", "sprop-sub-layer-id", "sprop-segmentation-id",
               "sprop-vps", "sprop-sps", "sprop-pps", "extra"]


def decode_h265_block(content: bytes) -> list[str]:
    """TR-10-15 Part 2 §16. The fixed part is 44 bytes including the 4-byte block header."""
    if len(content) < 40:
        return [f"  truncated H.265 block ({len(content)} bytes)"]

    mask = struct.unpack(">I", content[0:4])[0]
    present = [name for index, name in enumerate(H265_FIELDS) if mask & (1 << index)]
    profile_space, profile_id, level_id, tier_flag = content[4:8]
    compatibility = content[8:12].hex().upper()
    interop = content[12:18].hex().upper()
    vps_n, sps_n, pps_n, extra_n = content[36:40]

    lines = [
        f"  FIELD-PRESENT-MASK=0x{mask:08X} -> {', '.join(present) or 'nothing'}",
        f"  profile-space={profile_space} profile-id={profile_id} "
        f"level-id={level_id} (level {level_id / 30:.1f}) tier-flag={tier_flag}",
        f"  profile-compatibility-indicator={compatibility} interop-constraints={interop}",
    ]
    tail = content[40:]
    if vps_n:
        lines.append(f"  sprop-vps={text(tail[:vps_n])}")
    if sps_n:
        lines.append(f"  sprop-sps={text(tail[vps_n:vps_n + sps_n])}")
    if pps_n:
        lines.append(f"  sprop-pps={text(tail[vps_n + sps_n:vps_n + sps_n + pps_n])}")
    if extra_n:
        lines.append(f"  extra={extra_n} bytes")
    return lines


BLOCK_DECODERS = {0x0005: ("video", decode_video_block),
                  0x0009: ("H.265", decode_h265_block),
                  0x000A: ("H.264", decode_h264_block)}


class PcapWriter:
    """Wraps each datagram in synthetic Ethernet/IPv4/UDP headers and writes a classic pcap.

    Capturing loopback on macOS needs privileged access to a BPF device; synthesising the
    frames here keeps the dissector testable with plain `tshark -r`, no permissions involved.
    """

    LINKTYPE_ETHERNET = 1

    def __init__(self, path: str, destination_port: int):
        self.file = open(path, "wb")
        self.destination_port = destination_port
        self.file.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535,
                                    self.LINKTYPE_ETHERNET))

    def write(self, payload: bytes, when: float) -> None:
        udp = struct.pack(">HHHH", 50000, self.destination_port, 8 + len(payload), 0) + payload

        total = 20 + len(udp)
        ip = struct.pack(">BBHHHBBH4s4s",
                         0x45, 0, total, 0, 0, 64, 17, 0,
                         socket.inet_aton("127.0.0.1"), socket.inet_aton("127.0.0.1"))
        frame = b"\x02\x00\x00\x00\x00\x01\x02\x00\x00\x00\x00\x02\x08\x00" + ip + udp

        seconds = int(when)
        self.file.write(struct.pack("<IIII", seconds, int((when - seconds) * 1_000_000),
                                    len(frame), len(frame)))
        self.file.write(frame)

    def close(self) -> None:
        self.file.close()


def decode_sender_report(datagram: bytes) -> dict | None:
    if len(datagram) < 28:
        return None
    version = datagram[0] >> 6
    reception_report_count = datagram[0] & 0x1F
    payload_type = datagram[1]
    if version != 2 or payload_type != SR_PAYLOAD_TYPE:
        return None

    length_words = struct.unpack(">H", datagram[2:4])[0]
    ssrc, ptp_seconds, ptp_nanoseconds, rtp_timestamp, packets, octets = \
        struct.unpack(">IIIIII", datagram[4:28])

    report = {
        "rc": reception_report_count,
        "length_words": length_words,
        "ssrc": ssrc,
        "ptp_seconds": ptp_seconds,
        "ptp_nanoseconds": ptp_nanoseconds,
        "rtp_timestamp": rtp_timestamp,
        "packets": packets,
        "octets": octets,
        "blocks": [],
        "problems": [],
    }

    expected_length = len(datagram) // 4 - 1
    if length_words != expected_length:
        report["problems"].append(f"length field {length_words}, expected {expected_length}")
    if reception_report_count != 0:
        report["problems"].append("TR-10-1 §8.7: RC should be 0")
    if ptp_nanoseconds >= 1_000_000_000:
        report["problems"].append(
            f"NTP low word is {ptp_nanoseconds}, not a nanosecond count — "
            "TR-10-1 §8.7 requires the PTP truncated format, not an NTP fraction")

    if len(datagram) < 28 + INFO_BLOCK_HEADER_BYTES:
        report["problems"].append("no room for an IPMX Info Block")
        return report

    tag, info_length_words = struct.unpack(">HH", datagram[28:32])
    report["tag"] = tag
    report["info_length_words"] = info_length_words
    report["block_version"] = datagram[32]
    report["ts_refclk"] = text(datagram[36:100])
    report["mediaclk"] = text(datagram[100:112])
    if tag != IPMX_TAG:
        report["problems"].append(f"extension tag 0x{tag:04X}, expected 0x5831")
        return report

    extension_end = min(len(datagram), 28 + (info_length_words + 1) * 4)
    offset = 28 + INFO_BLOCK_HEADER_BYTES
    while offset + 4 <= extension_end:
        block_type, block_length_words = struct.unpack(">HH", datagram[offset:offset + 4])
        block_bytes = (block_length_words + 1) * 4
        if block_bytes < 4 or offset + block_bytes > extension_end:
            report["problems"].append(f"media info block at {offset} overruns the extension")
            break
        report["blocks"].append((block_type, datagram[offset + 4:offset + block_bytes]))
        offset += block_bytes
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--group", default="239.10.10.10", help="multicast group or bind address")
    parser.add_argument("--port", type=int, default=50001, help="RTCP port, i.e. media port + 1")
    parser.add_argument("--iface", default="0.0.0.0", help="interface to join the group on")
    parser.add_argument("--count", type=int, default=5, help="reports to decode before exiting")
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--pcap", help="also write what arrives to this pcap, for Wireshark "
                                       "and scripts/ipmx-rtcp.lua")
    args = parser.parse_args()

    capture = PcapWriter(args.pcap, args.port) if args.pcap else None

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", args.port))
    if int(args.group.split(".")[0]) in range(224, 240):
        membership = socket.inet_aton(args.group) + socket.inet_aton(args.iface)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, membership)
    sock.settimeout(args.timeout)

    print(f"listening for RTCP on {args.group}:{args.port}\n")

    decoded = 0
    problems = 0
    previous_rtp = None
    previous_wall = None
    intervals = []

    while decoded < args.count:
        try:
            datagram, _ = sock.recvfrom(65536)
        except socket.timeout:
            print(f"timed out after {args.timeout}s with {decoded} report(s)", file=sys.stderr)
            return 2 if decoded == 0 else 0

        now = time.monotonic()
        if capture:
            capture.write(datagram, time.time())
        report = decode_sender_report(datagram)
        if report is None:
            continue
        decoded += 1

        print(f"--- Sender Report {decoded} ({len(datagram)} bytes) ---")
        print(f"  SSRC=0x{report['ssrc']:08X} RC={report['rc']} length={report['length_words']}")
        print(f"  PTP {report['ptp_seconds']}s {report['ptp_nanoseconds']}ns "
              f"RTP={report['rtp_timestamp']}")
        print(f"  packets={report['packets']} octets={report['octets']}")
        if "tag" in report:
            print(f"  IPMX Info Block tag=0x{report['tag']:04X} "
                  f"length={report['info_length_words']} version={report['block_version']}")
            print(f"  ts-refclk={report['ts_refclk']} mediaclk={report['mediaclk']}")

        for block_type, content in report["blocks"]:
            name, decoder = BLOCK_DECODERS.get(block_type, (f"unknown 0x{block_type:04X}", None))
            print(f"  Media Info Block 0x{block_type:04X} ({name}), {len(content)} bytes")
            if decoder:
                for line in decoder(content):
                    print("  " + line)

        if previous_rtp is not None:
            print(f"  delta: RTP +{(report['rtp_timestamp'] - previous_rtp) & 0xFFFFFFFF} ticks, "
                  f"wall +{(now - previous_wall) * 1000:.2f} ms")
            intervals.append(now - previous_wall)
        previous_rtp = report["rtp_timestamp"]
        previous_wall = now

        for problem in report["problems"]:
            print(f"  PROBLEM: {problem}")
            problems += 1
        print()

    if capture:
        capture.close()
        print(f"wrote {decoded} datagram(s) to {args.pcap}\n")

    if intervals:
        mean = sum(intervals) / len(intervals)
        jitter = max(intervals) - min(intervals)
        print(f"cadence: mean {mean * 1000:.2f} ms, spread {jitter * 1000:.2f} ms "
              f"over {len(intervals)} intervals")

    print(f"\n{'FAILED — ' + str(problems) + ' problem(s)' if problems else 'ok — no problems'}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
