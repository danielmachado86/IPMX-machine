import Darwin
import Foundation

public enum SocketError: Error, CustomStringConvertible {
    case create(String)
    case option(String, Int32)
    case bind(Int32)
    case badAddress(String)
    case join(Int32)
    case send(Int32)

    public var description: String {
        switch self {
        case .create(let s):        return "socket() failed: \(s)"
        case .option(let n, let e): return "setsockopt(\(n)) failed: \(String(cString: strerror(e)))"
        case .bind(let e):          return "bind() failed: \(String(cString: strerror(e)))"
        case .badAddress(let a):    return "not a valid IPv4 address: \(a)"
        case .join(let e):          return "IP_ADD_MEMBERSHIP failed: \(String(cString: strerror(e)))"
        case .send(let e):          return "sendto() failed: \(String(cString: strerror(e)))"
        }
    }
}

public enum IPv4 {
    public static func parse(_ text: String) -> in_addr? {
        var addr = in_addr()
        return inet_pton(AF_INET, text, &addr) == 1 ? addr : nil
    }

    public static func isMulticast(_ text: String) -> Bool {
        guard let addr = parse(text) else { return false }
        let host = UInt32(bigEndian: addr.s_addr)
        return (host >> 28) == 0xE            // 224.0.0.0/4
    }

    /// First IPv4 address on an up, running, multicast-capable, non-loopback interface.
    /// Falls back to 127.0.0.1 so the loop still closes on a Mac with no network at all.
    public static func defaultInterfaceAddress() -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return "127.0.0.1" }
        defer { freeifaddrs(head) }

        var candidate: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = start
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0,
                  flags & IFF_MULTICAST != 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if !text.hasPrefix("169.254.") {          // skip link-local autoconfiguration
                candidate = text
                break
            }
            if candidate == nil { candidate = text }
        }
        return candidate ?? "127.0.0.1"
    }
}

private func makeSockAddr(_ address: in_addr, port: UInt16) -> sockaddr_in {
    var sin = sockaddr_in()
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_port = port.bigEndian
    sin.sin_addr = address
    return sin
}

// MARK: - Sender

public final class UDPSender {
    private let fd: Int32
    private var destination: sockaddr_in
    public let destinationDescription: String

    /// - Parameters:
    ///   - host: unicast or multicast IPv4 destination.
    ///   - interface: local IPv4 address of the egress interface. Setting this explicitly
    ///     matters on a Mac with Wi-Fi plus a Thunderbolt adapter, where the default route
    ///     is rarely the one you want the media on.
    public init(host: String, port: UInt16, interface: String, ttl: Int32 = 8, loopback: Bool = true) throws {
        guard let destAddr = IPv4.parse(host) else { throw SocketError.badAddress(host) }
        guard let ifAddr = IPv4.parse(interface) else { throw SocketError.badAddress(interface) }

        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw SocketError.create(String(cString: strerror(errno))) }

        destination = makeSockAddr(destAddr, port: port)
        destinationDescription = "\(host):\(port) via \(interface)"

        // A generous send buffer absorbs the burst at the head of each keyframe.
        var sendBuffer: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))

        if IPv4.isMulticast(host) {
            var out = ifAddr
            guard setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &out, socklen_t(MemoryLayout<in_addr>.size)) == 0 else {
                throw SocketError.option("IP_MULTICAST_IF", errno)
            }
            var hops = ttl
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &hops, socklen_t(MemoryLayout<Int32>.size))

            // Loopback on lets encoder and decoder run on the same Mac.
            var loop: UInt8 = loopback ? 1 : 0
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<UInt8>.size))
        }
    }

    deinit { close(fd) }

    public func send(_ payload: Data) throws {
        try payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let sent = withUnsafePointer(to: &destination) { dest -> Int in
                dest.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if sent < 0 { throw SocketError.send(errno) }
        }
    }
}

// MARK: - Receiver

public final class UDPReceiver {
    private let fd: Int32
    private var buffer = [UInt8](repeating: 0, count: 65536)

    public init(group: String, port: UInt16, interface: String, receiveBufferBytes: Int32 = 8 * 1024 * 1024) throws {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw SocketError.create(String(cString: strerror(errno))) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // macOS ships a small default. If this silently clamps, raise the ceiling:
        //   sudo sysctl -w kern.ipc.maxsockbuf=16777216
        var rcv = receiveBufferBytes
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))

        var local = makeSockAddr(in_addr(s_addr: INADDR_ANY), port: port)
        let bound = withUnsafePointer(to: &local) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw SocketError.bind(errno) }

        if IPv4.isMulticast(group) {
            guard let groupAddr = IPv4.parse(group) else { throw SocketError.badAddress(group) }
            guard let ifAddr = IPv4.parse(interface) else { throw SocketError.badAddress(interface) }
            var mreq = ip_mreq(imr_multiaddr: groupAddr, imr_interface: ifAddr)
            guard setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 else {
                close(fd); throw SocketError.join(errno)
            }
        }
    }

    deinit { close(fd) }

    /// Blocking receive of a single datagram.
    public func receive() -> Data? {
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { return nil }
        return Data(buffer[0..<n])
    }

    public func actualReceiveBufferBytes() -> Int32 {
        var value: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &value, &size)
        return value
    }
}
