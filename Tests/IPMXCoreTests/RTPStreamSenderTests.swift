import Foundation
import Testing
@testable import IPMXCore

/// The regression this suite exists for: when the shaper refuses an access unit, the sender
/// must leave no trace of it. A consumed sequence number would show up at the receiver as
/// network loss for packets that were never sent, and a partially admitted frame would put a
/// broken picture on the wire.
@Suite("RTP sender admission and sequence numbers")
struct RTPStreamSenderTests {

    /// Sends nowhere in particular. UDP to a closed local port succeeds, which is all the
    /// unshaped path needs.
    private static func discardSocket() throws -> UDPSender {
        try UDPSender(host: "127.0.0.1", port: 59_998, interface: "127.0.0.1")
    }

    /// A shaper whose worker parks in its first send, so the queue never drains and admission
    /// is entirely deterministic.
    private static func parkedShaper(capacity: Int)
        -> (shaper: TrafficShaper, parked: DispatchSemaphore, releaseAll: () -> Void) {
        let parked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let shaper = TrafficShaper(
            configuration: TrafficShaperConfiguration(
                parameters: TrafficShapeParameters(maxPacketRate: 1_000_000),
                queueCapacity: capacity
            )
        ) { _ in
            parked.signal()
            release.wait()
        }
        // Enough permits for every datagram the ring can hold, otherwise the worker simply
        // parks again inside the next send and never reaches the stop check.
        return (shaper, parked, { for _ in 0...(capacity + 1) { release.signal() } })
    }

    private static func accessUnit(packets: Int, mtu: Int = 1_400) -> [NALUnit] {
        // One NAL per packet keeps the arithmetic obvious.
        (0..<packets).map { _ in TestNAL.slice(codec: .h264, size: mtu) }
    }

    @Test("A refused access unit leaves the sequence number untouched", .timeLimit(.minutes(1)))
    func refusedAccessUnitDoesNotAdvanceSequence() throws {
        let (shaper, parked, releaseAll) = Self.parkedShaper(capacity: 4)
        defer {
            releaseAll()
            #expect(shaper.stop(drain: false, timeout: 2))
        }

        let sender = RTPStreamSender(socket: try Self.discardSocket(),
                                     packetizer: VideoPacketizer(codec: .h264),
                                     trafficShaper: shaper,
                                     initialSequenceNumber: 1_000)

        // Park the worker and fill the ring so the next access unit cannot fit.
        try sender.send(accessUnit: Self.accessUnit(packets: 4), timestamp: 900_000)
        #expect(parked.wait(timeout: .now() + 1) == .success)

        let sequenceBefore = sender.nextSequenceNumber
        let packetsBefore = sender.packetsSent
        let bytesBefore = sender.bytesSent
        let payloadBefore = sender.payloadBytesSent

        try sender.send(accessUnit: Self.accessUnit(packets: 8), timestamp: 903_000)

        #expect(sender.nextSequenceNumber == sequenceBefore,
                "a receiver would read a consumed sequence number as network loss")
        #expect(sender.packetsSent == packetsBefore)
        #expect(sender.bytesSent == bytesBefore)
        #expect(sender.payloadBytesSent == payloadBefore)
        #expect(sender.droppedAccessUnits == 1)
        #expect(sender.droppedPackets == 8)
    }

    @Test("An accepted access unit resumes the sequence contiguously", .timeLimit(.minutes(1)))
    func sequenceStaysContiguousAcrossADrop() throws {
        let (shaper, parked, releaseAll) = Self.parkedShaper(capacity: 3)
        defer {
            releaseAll()
            #expect(shaper.stop(drain: false, timeout: 2))
        }

        let sender = RTPStreamSender(socket: try Self.discardSocket(),
                                     packetizer: VideoPacketizer(codec: .h264),
                                     trafficShaper: shaper,
                                     initialSequenceNumber: 65_534)   // straddles the wrap

        try sender.send(accessUnit: Self.accessUnit(packets: 3), timestamp: 900_000)
        #expect(parked.wait(timeout: .now() + 1) == .success)
        #expect(sender.nextSequenceNumber == 1, "65534, 65535, 0 went out; 1 is next")

        // Refused: the ring has one free slot at most, and this needs four.
        try sender.send(accessUnit: Self.accessUnit(packets: 4), timestamp: 903_000)
        #expect(sender.droppedAccessUnits == 1)
        #expect(sender.nextSequenceNumber == 1, "still 1, nothing was spent")

        // A one-packet unit fits in the slot the worker freed, and continues from 1.
        try sender.send(accessUnit: Self.accessUnit(packets: 1), timestamp: 906_000)
        #expect(sender.droppedAccessUnits == 1)
        #expect(sender.nextSequenceNumber == 2,
                "the stream a receiver sees has no gap across the dropped frame")
    }

    @Test("Counters distinguish admitted from transmitted", .timeLimit(.minutes(1)))
    func admittedVersusTransmitted() throws {
        let (shaper, parked, releaseAll) = Self.parkedShaper(capacity: 8)
        defer {
            releaseAll()
            #expect(shaper.stop(drain: false, timeout: 2))
        }

        let sender = RTPStreamSender(socket: try Self.discardSocket(),
                                     packetizer: VideoPacketizer(codec: .h264),
                                     trafficShaper: shaper)

        try sender.send(accessUnit: Self.accessUnit(packets: 6), timestamp: 900_000)
        #expect(parked.wait(timeout: .now() + 1) == .success)

        #expect(sender.packetsSent == 6, "admitted to the queue")
        // The RTCP Sender Report must report what reached the network, not what is queued:
        // RFC 3550 §6.4.1 defines the counters that way.
        #expect(sender.packetsTransmitted < sender.packetsSent)
    }

    @Test("Without a shaper every packet goes straight out")
    func unshapedPathIsUnchanged() throws {
        let sender = RTPStreamSender(socket: try Self.discardSocket(),
                                     packetizer: VideoPacketizer(codec: .h264),
                                     trafficShaper: nil,
                                     initialSequenceNumber: 500)

        try sender.send(accessUnit: Self.accessUnit(packets: 5), timestamp: 900_000)

        #expect(sender.nextSequenceNumber == 505)
        #expect(sender.packetsSent == 5)
        #expect(sender.droppedAccessUnits == 0)
        #expect(sender.packetsTransmitted == 5, "with no shaper the two counters agree")
    }

    @Test("An empty access unit is a no-op")
    func emptyAccessUnit() throws {
        let sender = RTPStreamSender(socket: try Self.discardSocket(),
                                     packetizer: VideoPacketizer(codec: .h264),
                                     trafficShaper: nil,
                                     initialSequenceNumber: 42)
        try sender.send(accessUnit: [], timestamp: 900_000)
        #expect(sender.nextSequenceNumber == 42)
        #expect(sender.packetsSent == 0)
        #expect(sender.droppedAccessUnits == 0)
    }
}
