#!/usr/bin/env python3
"""Validate an externally captured RTP flow against the TR-10-7 CMAX token bucket.

This is intentionally independent from the Swift scheduler. It reads a classic PCAP captured
on another host, extracts IPv4/UDP/RTP packet timestamps, derives CMAX from MaxRate, and
replays the Network Compatibility token bucket.

Examples:
    python3 scripts/validate-traffic-shape.py capture.pcap --port 50000 \
        --max-packet-rate 1200
    python3 scripts/validate-traffic-shape.py capture.pcap --port 50000 \
        --bitrate-kbps 8000 --mtu 1400

For formal lab acceptance, open the same PCAP in EBU LIST and run its ST 2110-21 Network
Compatibility Model analysis. This script provides the fast independent check used during
development; it is not a replacement for EBU LIST.

Alcance de lo que esto prueba, y lo que no:

Este script reimplementa el MISMO token bucket que el emisor. Por tanto valida que el emisor
respeta el bucket que se le configuró, no que cumple ST 2110-21. El algoritmo normativo de
CINST vive en ST 2110-21, que es un estándar SMPTE de pago y no está en specs/. Si el modelo
que ambos comparten fuera incorrecto, los dos coincidirían igualmente.

Es una diferencia deliberada respecto a scripts/rtcp-monitor.py, que sí se escribió desde las
tablas de las TR y por eso sirve como comprobación independiente.
"""

import argparse
import math
import struct
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class PcapFormat:
    byte_order: str
    timestamp_scale: float
    link_type: int


def read_pcap(path: Path):
    with path.open("rb") as stream:
        header = stream.read(24)
        if len(header) != 24:
            raise ValueError("truncated PCAP global header")

        magic = header[:4]
        formats = {
            b"\xd4\xc3\xb2\xa1": ("<", 1e-6),
            b"\xa1\xb2\xc3\xd4": (">", 1e-6),
            b"\x4d\x3c\xb2\xa1": ("<", 1e-9),
            b"\xa1\xb2\x3c\x4d": (">", 1e-9),
        }
        if magic not in formats:
            if magic == b"\x0a\x0d\x0d\x0a":
                raise ValueError("PCAPNG is not supported; capture with tcpdump -w for classic PCAP")
            raise ValueError(f"unknown PCAP magic {magic.hex()}")

        byte_order, scale = formats[magic]
        _, _, _, _, _, link_type = struct.unpack(byte_order + "HHiIII", header[4:])
        fmt = PcapFormat(byte_order, scale, link_type)

        while True:
            record = stream.read(16)
            if not record:
                return
            if len(record) != 16:
                raise ValueError("truncated PCAP record header")
            seconds, fraction, captured, _ = struct.unpack(byte_order + "IIII", record)
            frame = stream.read(captured)
            if len(frame) != captured:
                raise ValueError("truncated PCAP packet")
            yield fmt, seconds + fraction * scale, frame


def ipv4_offset(frame: bytes, link_type: int) -> int | None:
    # DLT_EN10MB
    if link_type == 1:
        if len(frame) < 14:
            return None
        offset = 14
        ether_type = struct.unpack(">H", frame[12:14])[0]
        while ether_type in (0x8100, 0x88A8):
            if len(frame) < offset + 4:
                return None
            ether_type = struct.unpack(">H", frame[offset + 2:offset + 4])[0]
            offset += 4
        return offset if ether_type == 0x0800 else None

    # DLT_NULL / DLT_LOOP, useful for macOS loopback captures.
    if link_type in (0, 108):
        return 4 if len(frame) >= 4 else None

    # DLT_LINUX_SLL
    if link_type == 113:
        return 16 if len(frame) >= 16 and frame[14:16] == b"\x08\x00" else None

    raise ValueError(f"unsupported PCAP link type {link_type}")


def rtp_packet(frame: bytes, link_type: int, destination_port: int):
    ip = ipv4_offset(frame, link_type)
    if ip is None or len(frame) < ip + 20 or frame[ip] >> 4 != 4:
        return None
    ihl = (frame[ip] & 0x0F) * 4
    if ihl < 20 or len(frame) < ip + ihl + 8 or frame[ip + 9] != 17:
        return None

    udp = ip + ihl
    source_port, port, udp_length = struct.unpack(">HHH", frame[udp:udp + 6])
    if port != destination_port or udp_length < 8:
        return None

    payload = frame[udp + 8:udp + udp_length]
    if len(payload) < 12 or payload[0] >> 6 != 2:
        return None

    sequence = struct.unpack(">H", payload[2:4])[0]
    timestamp = struct.unpack(">I", payload[4:8])[0]
    return source_port, sequence, timestamp, len(payload)


def estimated_packet_rate(bitrate_kbps: int, mtu: int, fill: float,
                          frame_rate: int, auxiliary_packets_per_frame: int) -> int:
    coded = math.ceil(bitrate_kbps * 1000 / (mtu * 8 * fill))
    return coded + frame_rate * auxiliary_packets_per_frame


def validate(timestamps: list[float], max_rate: float, cmax: int,
             tolerance_seconds: float):
    tokens = float(cmax)
    previous = timestamps[0]
    violations = []
    worst_delay = 0.0

    for index, captured in enumerate(timestamps):
        elapsed = max(0.0, captured - previous)
        tokens = min(float(cmax), tokens + elapsed * max_rate)
        previous = captured

        if tokens >= 1.0:
            tokens -= 1.0
            continue

        required_delay = (1.0 - tokens) / max_rate
        worst_delay = max(worst_delay, required_delay)
        if required_delay > tolerance_seconds:
            violations.append((index, captured, required_delay))
        # Treat a within-tolerance packet as exactly on its legal boundary so capture jitter
        # does not compound into false failures later in the stream.
        tokens = 0.0

    return violations, worst_delay


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pcap", type=Path)
    parser.add_argument("--port", type=int, default=50000, help="RTP destination port")
    rate = parser.add_mutually_exclusive_group(required=True)
    rate.add_argument("--max-packet-rate", type=float,
                      help="TR-10-7 MaxRate in RTP packets per second")
    rate.add_argument("--bitrate-kbps", type=int,
                      help="derive MaxRate conservatively from bitrate, MTU, and fill")
    parser.add_argument("--mtu", type=int, default=1400, help="maximum RTP payload bytes")
    parser.add_argument("--fill", type=float, default=0.75,
                        help="minimum average RTP payload fill for bitrate conversion")
    parser.add_argument("--fps", type=int, default=60,
                        help="frame rate used for the auxiliary-packet allowance")
    parser.add_argument("--aux-packets-per-frame", type=int, default=4,
                        help="parameter-set, SEI, and partial-packet allowance")
    parser.add_argument("--tolerance-us", type=float, default=10.0,
                        help="external capture timestamp tolerance")
    args = parser.parse_args()

    if args.max_packet_rate is not None:
        max_rate = args.max_packet_rate
    else:
        if (args.bitrate_kbps <= 0 or args.mtu <= 0 or args.fps <= 0
                or args.aux_packets_per_frame < 0 or not 0 < args.fill <= 1):
            parser.error("bitrate, MTU, and fps must be positive; fill must be <= 1")
        max_rate = estimated_packet_rate(args.bitrate_kbps, args.mtu, args.fill,
                                         args.fps, args.aux_packets_per_frame)
    if max_rate <= 0:
        parser.error("MaxRate must be positive")

    cmax = max(16, int(max_rate / 21_600))
    packets = []
    sequences = []
    try:
        for fmt, captured, frame in read_pcap(args.pcap):
            parsed = rtp_packet(frame, fmt.link_type, args.port)
            if parsed is not None:
                _, sequence, _, _ = parsed
                packets.append(captured)
                sequences.append(sequence)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    if not packets:
        print(f"error: no RTP packets found for UDP destination port {args.port}",
              file=sys.stderr)
        return 2

    origin = packets[0]
    relative = [value - origin for value in packets]
    violations, worst = validate(relative, max_rate, cmax,
                                 args.tolerance_us / 1_000_000)
    duration = max(relative[-1], 0)
    observed_rate = (len(relative) - 1) / duration if duration > 0 else math.inf

    gaps = 0
    for previous, current in zip(sequences, sequences[1:]):
        if current != (previous + 1) & 0xFFFF:
            gaps += 1

    print(f"RTP packets:          {len(relative)}")
    print(f"capture duration:     {duration:.6f} s")
    print(f"observed packet rate: {observed_rate:.2f} packets/s")
    print(f"TR-10-7 MaxRate:      {max_rate:.2f} packets/s")
    print(f"TR-10-7 CMAX:         {cmax}")
    print(f"capture tolerance:    {args.tolerance_us:.1f} us")
    print(f"sequence gaps:        {gaps}")
    print(f"worst timing deficit: {worst * 1_000_000:.3f} us")

    if violations:
        print(f"FAIL: {len(violations)} packet(s) exceeded the token-bucket bound")
        for index, timestamp, deficit in violations[:10]:
            print(f"  packet {index}: t={timestamp:.9f}s, "
                  f"needs {deficit * 1_000_000:.3f} us more spacing")
        return 1

    print("PASS: capture satisfies the configured CINST/CMAX token-bucket bound")
    return 0


if __name__ == "__main__":
    sys.exit(main())
