import Foundation

/// Stamps packetizer output with RTP headers and pushes it out the socket.
///
/// Phase 0 sends each access unit as fast as the socket accepts it. There is no traffic
/// shaping: the CINST/CMAX model of TR-10-7 §10 is Phase 3, and on macOS it needs a
/// real-time thread of its own (no SO_TXTIME in this kernel).
public final class RTPStreamSender {
    public let payloadType: UInt8
    public let ssrc: UInt32

    private let socket: UDPSender
    private let packetizer: VideoPacketizer
    private var sequenceNumber: UInt16

    public private(set) var packetsSent: UInt64 = 0
    public private(set) var bytesSent: UInt64 = 0
    /// Payload octets only, excluding RTP headers and padding — what the RTCP Sender Report's
    /// "sender's octet count" is defined to hold (RFC 3550 §6.4.1).
    public private(set) var payloadBytesSent: UInt64 = 0

    public init(socket: UDPSender,
                packetizer: VideoPacketizer,
                payloadType: UInt8 = 96,
                ssrc: UInt32 = UInt32.random(in: 1...UInt32.max)) {
        self.socket = socket
        self.packetizer = packetizer
        self.payloadType = payloadType
        self.ssrc = ssrc
        self.sequenceNumber = UInt16.random(in: 0...UInt16.max)
    }

    /// Sends one access unit. All packets share `timestamp`; the last one carries the marker bit.
    public func send(accessUnit units: [NALUnit], timestamp: UInt32) throws {
        let payloads = packetizer.packetize(accessUnit: units)
        guard !payloads.isEmpty else { return }

        for (index, payload) in payloads.enumerated() {
            let header = RTPHeader(
                payloadType: payloadType,
                sequenceNumber: sequenceNumber,
                timestamp: timestamp,
                ssrc: ssrc,
                marker: index == payloads.count - 1
            )
            var datagram = header.serialized()
            datagram.append(payload)
            try socket.send(datagram)

            sequenceNumber = sequenceNumber &+ 1
            packetsSent += 1
            bytesSent += UInt64(datagram.count)
            payloadBytesSent += UInt64(payload.count)
        }
    }
}
