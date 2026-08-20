import Foundation
import Testing
@testable import IPMXCore

/// Found with two encoders left running on the same multicast group: the receiver reported
/// 6.1 billion lost packets and decoded nothing, because sequence numbers are only meaningful
/// within one SSRC (RFC 3550 §5.1) and the reassembler was fed both interleaved.
@Suite("RTP source filter")
struct RTPSourceFilterTests {

    @Test("The first source seen becomes the one that is followed")
    func locksToFirstSource() {
        var filter = RTPSourceFilter()
        #expect(filter.lockedSource == nil)

        let firstPacket = filter.accept(ssrc: 0xAAAA, now: 0)
        #expect(firstPacket)
        #expect(filter.lockedSource == 0xAAAA)
        let secondPacket = filter.accept(ssrc: 0xAAAA, now: 0.01)
        #expect(secondPacket)
        #expect(filter.acceptedPackets == 2)
        #expect(filter.rejectedPackets == 0)
    }

    @Test("A second sender on the same address is refused, not interleaved")
    func rejectsForeignSource() {
        var filter = RTPSourceFilter()
        let initialLock = filter.accept(ssrc: 0xAAAA, now: 0)
        #expect(initialLock)

        for step in 1...10 {
            let now = Double(step) * 0.01
            let fromIncumbent = filter.accept(ssrc: 0xAAAA, now: now)
            #expect(fromIncumbent)
            let fromIntruder = filter.accept(ssrc: 0xBBBB, now: now)
            #expect(!fromIntruder, "the intruder never gets through")
        }

        #expect(filter.lockedSource == 0xAAAA)
        #expect(filter.acceptedPackets == 11)
        #expect(filter.rejectedPackets == 10)
        #expect(filter.foreignSources == [0xBBBB])
        #expect(filter.relocks == 0)
    }

    /// Without this, restarting the encoder — which gives it a fresh SSRC — would leave the
    /// receiver deaf until it too was restarted.
    @Test("A silent source releases the lock so a restarted sender is picked up")
    func relocksAfterSilence() {
        var filter = RTPSourceFilter(relockAfter: 2.0)
        let initial = filter.accept(ssrc: 0xAAAA, now: 0)
        #expect(initial)

        // Still inside the window: the newcomer waits.
        let tooSoon = filter.accept(ssrc: 0xBBBB, now: 1.9)
        #expect(!tooSoon)
        #expect(filter.lockedSource == 0xAAAA)

        // The original has gone quiet for long enough.
        let afterSilence = filter.accept(ssrc: 0xBBBB, now: 2.1)
        #expect(afterSilence)
        #expect(filter.lockedSource == 0xBBBB)
        #expect(filter.relocks == 1)
    }

    @Test("Traffic from the locked source keeps postponing a relock")
    func activeSourceHoldsTheLock() {
        var filter = RTPSourceFilter(relockAfter: 1.0)
        let initialA = filter.accept(ssrc: 0xAAAA, now: 0)
        #expect(initialA)

        // A steady stream from the incumbent, with an intruder trying throughout.
        for step in 1...20 {
            let now = Double(step) * 0.5
            let firstPacket0 = filter.accept(ssrc: 0xAAAA, now: now)
            #expect(firstPacket0)
            let firstPacket1 = filter.accept(ssrc: 0xBBBB, now: now)
            #expect(!firstPacket1)
        }
        #expect(filter.lockedSource == 0xAAAA)
        #expect(filter.relocks == 0)
    }

    @Test("The set of intruders is bounded")
    func foreignSourcesAreBounded() {
        var filter = RTPSourceFilter()
        let firstPacket2 = filter.accept(ssrc: 1, now: 0)
        #expect(firstPacket2)

        for source in UInt32(100)..<UInt32(200) {
            let firstPacket3 = filter.accept(ssrc: source, now: 0.01)
            #expect(!firstPacket3)
        }
        #expect(filter.foreignSources.count == RTPSourceFilter.maximumTrackedForeignSources)
        #expect(filter.rejectedPackets == 100, "still counted, just not all remembered")
    }

    @Test("The conflict description names both sides, which is what was missing")
    func conflictDescription() throws {
        var filter = RTPSourceFilter()
        #expect(filter.conflictDescription == nil, "nothing to report before a conflict")

        let firstPacket4 = filter.accept(ssrc: 0x55F70B3F, now: 0)
        #expect(firstPacket4)
        #expect(filter.conflictDescription == nil, "one sender is not a conflict")

        let firstPacket5 = filter.accept(ssrc: 0x3074EC7A, now: 0.01)
        #expect(!firstPacket5)
        let description = try #require(filter.conflictDescription)
        #expect(description.contains("55f70b3f"))
        #expect(description.contains("3074ec7a"))
    }

    /// The scenario as it actually happened, reduced: two senders alternating packet by packet.
    /// Half the traffic is refused and the reassembler downstream sees one clean sequence.
    @Test("Two interleaved senders yield one clean stream")
    func interleavedSendersAreSeparated() {
        var filter = RTPSourceFilter()
        var deliveredSequences: [UInt16] = []
        var sequenceA: UInt16 = 0
        var sequenceB: UInt16 = 40_000

        for step in 0..<100 {
            let now = Double(step) * 0.001
            if filter.accept(ssrc: 0x1111, now: now) { deliveredSequences.append(sequenceA) }
            sequenceA &+= 1
            if filter.accept(ssrc: 0x2222, now: now) { deliveredSequences.append(sequenceB) }
            sequenceB &+= 1
        }

        #expect(deliveredSequences.count == 100)
        #expect(deliveredSequences == (0..<100).map { UInt16($0) },
                "contiguous, so the depacketizer sees no phantom loss")
    }
}
