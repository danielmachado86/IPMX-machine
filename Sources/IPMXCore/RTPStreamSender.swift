import Foundation

/// Stamps packetizer output with RTP headers and pushes it out the socket.
///
/// When a traffic-shape configuration is supplied, complete datagrams go through a dedicated
/// real-time worker which enforces the CINST/CMAX token-bucket bound from TR-10-7 §10.
public final class RTPStreamSender {
    public let payloadType: UInt8
    public let ssrc: UInt32

    private let socket: UDPSender
    private let packetizer: VideoPacketizer
    private let trafficShaper: TrafficShaper?
    private var sequenceNumber: UInt16

    public private(set) var packetsSent: UInt64 = 0
    public private(set) var bytesSent: UInt64 = 0
    /// Payload octets only, excluding RTP headers and padding — what the RTCP Sender Report's
    /// "sender's octet count" is defined to hold (RFC 3550 §6.4.1).
    public private(set) var payloadBytesSent: UInt64 = 0

    public convenience init(socket: UDPSender,
                            packetizer: VideoPacketizer,
                            trafficShape: TrafficShaperConfiguration? = nil,
                            payloadType: UInt8 = 96,
                            ssrc: UInt32 = UInt32.random(in: 1...UInt32.max)) {
        self.init(socket: socket,
                  packetizer: packetizer,
                  trafficShaper: trafficShape.map { TrafficShaper(socket: socket, configuration: $0) },
                  payloadType: payloadType,
                  ssrc: ssrc,
                  initialSequenceNumber: UInt16.random(in: 0...UInt16.max))
    }

    /// Injectable form. Exists so the admission and sequence-number behaviour can be tested
    /// against a shaper whose drain is controlled, and from a known starting sequence.
    init(socket: UDPSender,
         packetizer: VideoPacketizer,
         trafficShaper: TrafficShaper?,
         payloadType: UInt8 = 96,
         ssrc: UInt32 = UInt32.random(in: 1...UInt32.max),
         initialSequenceNumber: UInt16 = UInt16.random(in: 0...UInt16.max)) {
        self.socket = socket
        self.packetizer = packetizer
        self.trafficShaper = trafficShaper
        self.payloadType = payloadType
        self.ssrc = ssrc
        self.sequenceNumber = initialSequenceNumber
    }

    /// The next sequence number that will go on the wire. Only meaningful for tests.
    var nextSequenceNumber: UInt16 { sequenceNumber }

    /// Access units the shaper had no room for. A frame lost under overload is recoverable;
    /// stalling the producer would stop the RTCP Sender Report cadence, which is not.
    public private(set) var droppedAccessUnits: UInt64 = 0
    public private(set) var droppedPackets: UInt64 = 0

    /// Sends one access unit. All packets share `timestamp`; the last one carries the marker bit.
    ///
    /// With a shaper attached the whole access unit is admitted or none of it is: a partially
    /// sent frame is worse than a dropped one, and abandoning it half way would also consume
    /// sequence numbers for packets that never leave, which a receiver would read as network
    /// loss. Sequence numbers are therefore only committed once admission succeeds.
    public func send(accessUnit units: [NALUnit], timestamp: UInt32) throws {
        let payloads = packetizer.packetize(accessUnit: units)
        guard !payloads.isEmpty else { return }

        // Build against a tentative sequence so nothing is committed until the whole access
        // unit is known to be going out.
        var tentativeSequence = sequenceNumber
        var batch: [TrafficShaper.PendingDatagram] = []
        batch.reserveCapacity(payloads.count)

        for (index, payload) in payloads.enumerated() {
            let header = RTPHeader(
                payloadType: payloadType,
                sequenceNumber: tentativeSequence,
                timestamp: timestamp,
                ssrc: ssrc,
                marker: index == payloads.count - 1
            )
            var datagram = header.serialized()
            datagram.append(payload)
            batch.append(TrafficShaper.PendingDatagram(bytes: datagram,
                                                       payloadOctets: payload.count))
            tentativeSequence = tentativeSequence &+ 1
        }

        if let trafficShaper {
            guard trafficShaper.enqueue(batch) else {
                droppedAccessUnits &+= 1
                droppedPackets &+= UInt64(batch.count)
                reportDrop(packets: batch.count)
                return
            }
        } else {
            // Unshaped: commit per packet, because a socket error mid-way means the earlier
            // ones really did go out and their sequence numbers are spent.
            for datagram in batch {
                try socket.send(datagram.bytes)
                sequenceNumber = sequenceNumber &+ 1
                packetsSent += 1
                bytesSent += UInt64(datagram.bytes.count)
                payloadBytesSent += UInt64(datagram.payloadOctets)
            }
            return
        }

        sequenceNumber = tentativeSequence
        packetsSent += UInt64(batch.count)
        bytesSent += batch.reduce(0) { $0 + UInt64($1.bytes.count) }
        payloadBytesSent += batch.reduce(0) { $0 + UInt64($1.payloadOctets) }
    }

    /// Rate limited so a sustained overload does not itself become the bottleneck.
    private func reportDrop(packets: Int) {
        guard droppedAccessUnits == 1 || droppedAccessUnits % 60 == 0 else { return }
        Log.error("traffic shaper queue full: dropped access unit "
                + "(\(packets) packets, \(droppedAccessUnits) so far). "
                + "MaxRate is below what the encoder produces — raise --max-packet-rate "
                + "or lower --bitrate")
    }

    public var trafficShapeSnapshot: TrafficShaperSnapshot? {
        trafficShaper?.snapshot()
    }

    /// Counts which are already on the wire, rather than merely admitted to the shaping queue.
    public var packetsTransmitted: UInt64 {
        trafficShaper?.snapshot().packetsSent ?? packetsSent
    }

    public var payloadBytesTransmitted: UInt64 {
        trafficShaper?.snapshot().payloadBytesSent ?? payloadBytesSent
    }

    /// Drains the shaped queue before shutdown. A sender without shaping has nothing to drain.
    @discardableResult
    public func shutdown(drain: Bool = true, timeout: TimeInterval = 5) -> Bool {
        trafficShaper?.stop(drain: drain, timeout: timeout) ?? true
    }
}
