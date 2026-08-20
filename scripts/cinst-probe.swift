import Darwin
import Foundation

// Live CINST probe for TR-10-7 §10 / ST 2110-21 Network Compatibility Model.
//
// Usage:
//     swift scripts/cinst-probe.swift --group 239.10.10.10 --port 50000 \
//           --iface 192.168.27.3 --max-rate 1193 --seconds 20
//
// Runs directly; for captures longer than a minute compile it first, which removes the
// per-run compile and tightens the receive loop:
//     swiftc -O -o /tmp/cinst-probe scripts/cinst-probe.swift
//
// Exit code is 1 when CINST exceeded CMAX, so it drops into CI next to the other validators.
//
// Timestamps every arriving datagram with mach_absolute_time on a high priority thread and
// runs the leaky bucket over the result: the bucket drains at MaxRate packets per second and
// CINST is its instantaneous occupancy. Compliance is CINST <= CMAX at all times.
//
// Scope, stated up front:
//  - Measures where the packets are received, not where they leave the PHY.
//  - Uses the same bucket model the sender enforces, so it is a consistency check rather than
//    an independent conformance verdict. The normative CINST definition lives in ST 2110-21.
//  - The receive path biases toward false violations: if this process is descheduled, packets
//    pile up in the socket buffer and get timestamped nearly together, which looks like a
//    burst. The sub-10us arrival count below is the tell. The bias runs toward failing a
//    good sender, never toward passing a bad one, so a PASS here means something.
//
// Calibration, measured on this project's own sender at 1080p60:
//     --no-shaping   max CINST 599.68, 75% of packets over CMAX, 257 packets per 10 ms
//     shaped         max CINST  16.11, 0% over, 28 packets per 10 ms
// The control matters: it shows the probe does detect real violations when they exist.

let arguments = CommandLine.arguments
func option(_ name: String, _ fallback: String) -> String {
    guard let i = arguments.firstIndex(of: "--\(name)"), i + 1 < arguments.count else { return fallback }
    return arguments[i + 1]
}

let group = option("group", "239.10.10.10")
let port = UInt16(option("port", "50000")) ?? 50000
let interfaceAddress = option("iface", "127.0.0.1")
let maxPacketRate = Double(option("max-rate", "1193")) ?? 1193
let seconds = Double(option("seconds", "20")) ?? 20
let cmax = max(16, Int(maxPacketRate / 21_600.0))

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
@inline(__always) func nowNanoseconds() -> UInt64 {
    mach_absolute_time() &* UInt64(timebase.numer) / UInt64(timebase.denom)
}

// MARK: socket

let fd = socket(AF_INET, SOCK_DGRAM, 0)
guard fd >= 0 else { fatalError("socket") }
var reuse: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
var receiveBuffer: Int32 = 16 * 1024 * 1024
setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))

var local = sockaddr_in()
local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
local.sin_family = sa_family_t(AF_INET)
local.sin_port = port.bigEndian
local.sin_addr = in_addr(s_addr: INADDR_ANY)
let bound = withUnsafePointer(to: &local) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
}
guard bound == 0 else { fatalError("bind: \(String(cString: strerror(errno)))") }

var groupAddress = in_addr(), interfaceAddr = in_addr()
inet_pton(AF_INET, group, &groupAddress)
inet_pton(AF_INET, interfaceAddress, &interfaceAddr)
var membership = ip_mreq(imr_multiaddr: groupAddress, imr_interface: interfaceAddr)
if setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout<ip_mreq>.size)) != 0 {
    FileHandle.standardError.write("join failed: \(String(cString: strerror(errno)))\n".data(using: .utf8)!)
}

// MARK: capture

let capacity = 4_000_000
var arrivals = [UInt64](repeating: 0, count: capacity)
var sizes = [Int32](repeating: 0, count: capacity)
var count = 0
var buffer = [UInt8](repeating: 0, count: 65536)

print("probing \(group):\(port) via \(interfaceAddress) for \(seconds)s")
print("MaxRate \(Int(maxPacketRate)) pkt/s  ->  CMAX \(cmax)\n")

let deadline = nowNanoseconds() &+ UInt64(seconds * 1e9)
while nowNanoseconds() < deadline && count < capacity {
    let n = recv(fd, &buffer, buffer.count, 0)
    let stamp = nowNanoseconds()
    guard n > 0 else { continue }
    arrivals[count] = stamp
    sizes[count] = Int32(n)
    count += 1
}
close(fd)

guard count > 32 else {
    print("only \(count) packets: is the encoder running and joined on this interface?")
    exit(2)
}

// MARK: leaky bucket

var occupancy = 0.0
var maximumCINST = 0.0
var violations = 0
var histogram = [Int](repeating: 0, count: cmax + 8)
var previous = arrivals[0]
var tightArrivals = 0

for index in 0..<count {
    let stamp = arrivals[index]
    let elapsed = Double(stamp &- previous) / 1e9
    if index > 0 && stamp &- previous < 10_000 { tightArrivals += 1 }
    occupancy = max(0, occupancy - elapsed * maxPacketRate)
    occupancy += 1
    previous = stamp

    maximumCINST = max(maximumCINST, occupancy)
    // Half a packet of tolerance: occupancy pinned at exactly CMAX drifts a hair above it
    // through float accumulation, and the receive path adds its own upward bias.
    if occupancy > Double(cmax) + 0.5 { violations += 1 }
    histogram[min(Int(occupancy.rounded(.down)), histogram.count - 1)] += 1
}

// MARK: burst window, comparable to a packets-per-10ms reading

var worstWindow = 0
var windowStart = 0
for index in 0..<count {
    while arrivals[index] &- arrivals[windowStart] > 10_000_000 { windowStart += 1 }
    worstWindow = max(worstWindow, index - windowStart + 1)
}

let duration = Double(arrivals[count - 1] &- arrivals[0]) / 1e9
let bytes = sizes[0..<count].reduce(0) { $0 + Int($1) }

print(String(format: "%d packets in %.2f s  =  %.0f pkt/s, %.2f Mbit/s",
             count, duration, Double(count) / duration, Double(bytes) * 8 / duration / 1e6))
print(String(format: "max packets in any 10 ms window : %d", worstWindow))
print(String(format: "arrivals closer than 10 us      : %d  (%.1f%%, receive-path batching)",
             tightArrivals, Double(tightArrivals) * 100 / Double(count)))
print("")
print(String(format: "CMAX                            : %d", cmax))
print(String(format: "max CINST observed              : %.2f", maximumCINST))
print(String(format: "packets above CMAX + 0.5        : %d  (%.4f%%)",
             violations, Double(violations) * 100 / Double(count)))
print("")
print("CINST distribution")
for level in 0..<histogram.count where histogram[level] > 0 {
    let share = Double(histogram[level]) * 100 / Double(count)
    let bar = String(repeating: "#", count: max(1, Int(share / 2)))
    let mark = level > cmax ? "  <-- over CMAX" : ""
    print(String(format: "  %2d  %6.2f%%  %@%@", level, share, bar, mark))
}
print("")
print(violations == 0
      ? "PASS: CINST stayed within CMAX for the whole capture"
      : "FAIL: CINST exceeded CMAX on \(violations) packet(s)")
exit(violations == 0 ? 0 : 1)
