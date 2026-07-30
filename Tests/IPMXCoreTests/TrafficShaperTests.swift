import Foundation
import Testing
@testable import IPMXCore

@Suite("Traffic shaping (TR-10-7 §10)")
struct TrafficShaperTests {

    @Test("CMAX follows max(16, floor(MaxRate / 21600))", arguments: [
        (1.0, 16),
        (21_599.0, 16),
        (21_600.0, 16),
        (345_599.0, 16),
        (345_600.0, 16),
        (367_199.0, 16),
        (367_200.0, 17),
        (1_080_000.0, 50),
    ])
    func cmax(maxPacketRate: Double, expected: Int) {
        #expect(TrafficShapeParameters(maxPacketRate: maxPacketRate).cmax == expected)
    }

    @Test("Bitrate conversion accounts for partial and auxiliary RTP packets")
    func estimatedPacketRate() {
        let estimate = TrafficShapeParameters.estimatedMaxPacketRate(
            maxBitrateKbps: 8_000,
            maxRTPPayloadBytes: 1_400,
            frameRate: 60
        )
        #expect(estimate == 1_193)

        let measuredOverride = TrafficShapeParameters(maxPacketRate: 1_200)
        #expect(measuredOverride.maxPacketRate == 1_200)
        #expect(measuredOverride.cmax == 16)
    }

    @Test("The initial burst is capped at CMAX and subsequent packets are paced")
    func initialBurstAndPacing() {
        let parameters = TrafficShapeParameters(maxPacketRate: 1_000)
        var bucket = TrafficShapeTokenBucket(parameters: parameters, originNanoseconds: 0)

        var deadlines: [UInt64] = []
        for _ in 0..<(parameters.cmax + 4) {
            deadlines.append(bucket.reserve(nowNanoseconds: 0))
        }

        #expect(deadlines.prefix(parameters.cmax).allSatisfy { $0 == 0 })
        #expect(deadlines[parameters.cmax] == 1_000_000)
        #expect(deadlines[parameters.cmax + 1] == 2_000_000)
        #expect(deadlines[parameters.cmax + 3] == 4_000_000)
    }

    @Test("An idle period refills only up to CMAX")
    func refillIsBounded() {
        let parameters = TrafficShapeParameters(maxPacketRate: 2_000)
        var bucket = TrafficShapeTokenBucket(parameters: parameters, originNanoseconds: 0)

        for _ in 0..<parameters.cmax {
            #expect(bucket.reserve(nowNanoseconds: 0) == 0)
        }

        let afterIdle: UInt64 = 10_000_000_000
        for _ in 0..<parameters.cmax {
            #expect(bucket.reserve(nowNanoseconds: afterIdle) == afterIdle)
        }
        #expect(bucket.reserve(nowNanoseconds: afterIdle) > afterIdle)
    }

    @Test("The asynchronous worker preserves datagram order and drains")
    func workerOrderAndDrain() throws {
        final class Recorder: @unchecked Sendable {
            let lock = NSLock()
            var values: [UInt8] = []

            func append(_ value: UInt8) {
                lock.lock()
                values.append(value)
                lock.unlock()
            }

            func snapshot() -> [UInt8] {
                lock.lock()
                defer { lock.unlock() }
                return values
            }
        }

        let recorder = Recorder()
        let configuration = TrafficShaperConfiguration(
            parameters: TrafficShapeParameters(maxPacketRate: 1_000),
            queueCapacity: 64,
            spinThresholdNanoseconds: 20_000
        )
        let shaper = TrafficShaper(configuration: configuration) { datagram in
            recorder.append(datagram[datagram.startIndex])
        }

        for value in UInt8(0)..<UInt8(24) {
            #expect(shaper.enqueue(Data([value]), payloadOctets: 1))
        }

        #expect(shaper.stop(drain: true, timeout: 2))
        #expect(recorder.snapshot() == Array(UInt8(0)..<UInt8(24)))

        let snapshot = shaper.snapshot()
        #expect(snapshot.state == .stopped)
        #expect(snapshot.packetsSent == 24)
        #expect(snapshot.bytesSent == 24)
        #expect(snapshot.payloadBytesSent == 24)
        #expect(snapshot.sendErrors == 0)
        #expect(snapshot.queueHighWatermark > 0)
    }
}

@Suite("Traffic shaper admission control")
struct TrafficShaperAdmissionTests {

    /// A shaper whose worker parks inside the very first send, so once `parked` is signalled
    /// the queue cannot change underneath an assertion.
    private static func parkedShaper(capacity: Int) -> (TrafficShaper, DispatchSemaphore) {
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
        return (shaper, parked)
    }

    /// The regression that matters: enqueue must never block the caller. The producer is the
    /// cadence thread, and blocking it stops the RTCP Sender Report cadence TR-10-15 §15
    /// requires to be constant.
    @Test("A full queue is refused instead of blocking the producer", .timeLimit(.minutes(1)))
    func fullQueueDoesNotBlock() {
        let (shaper, parked) = Self.parkedShaper(capacity: 4)
        defer { _ = shaper.stop(drain: false, timeout: 1) }

        var admitted = 0
        for value in UInt8(0)..<UInt8(64) where shaper.enqueue(Data([value]), payloadOctets: 1) {
            admitted += 1
        }
        _ = parked.wait(timeout: .now() + 1)

        #expect(admitted >= 4, "the ring itself must fill")
        #expect(admitted <= 5, "at most the ring plus the one the worker took")
        // Reaching here at all is the assertion: the old blocking enqueue never returned.
    }

    @Test("A batch is admitted whole or not at all", .timeLimit(.minutes(1)))
    func batchIsAtomic() {
        let (shaper, parked) = Self.parkedShaper(capacity: 8)
        defer { _ = shaper.stop(drain: false, timeout: 1) }

        func batch(_ count: Int) -> [TrafficShaper.PendingDatagram] {
            (0..<count).map { .init(bytes: Data([UInt8($0)]), payloadOctets: 1) }
        }

        // Park the worker first so nothing drains while the queue depth is being compared.
        #expect(shaper.enqueue(batch(1)))
        #expect(parked.wait(timeout: .now() + 1) == .success)

        #expect(shaper.enqueue(batch(6)))
        let before = shaper.snapshot().queuedPackets
        #expect(!shaper.enqueue(batch(6)), "a batch that does not fit is refused outright")
        #expect(shaper.snapshot().queuedPackets == before, "and leaves nothing behind")
    }

    @Test("An empty batch is trivially accepted")
    func emptyBatch() {
        let (shaper, _) = Self.parkedShaper(capacity: 4)
        defer { _ = shaper.stop(drain: false, timeout: 1) }
        #expect(shaper.enqueue([]))
    }

    @Test("A stopped shaper refuses everything")
    func stoppedRefuses() {
        let (shaper, _) = Self.parkedShaper(capacity: 8)
        _ = shaper.stop(drain: false, timeout: 1)
        #expect(!shaper.enqueue(Data([0]), payloadOctets: 1))
        #expect(shaper.availableCapacity == 0)
    }
}

@Suite("Traffic shaper observability")
struct TrafficShaperObservabilityTests {

    /// The old `latePackets` counter measured the busy-wait overshoot, so it read zero even
    /// with thousands of packets backed up. Residency is the figure that actually moves.
    @Test("Queue residency reflects the time a packet waited", .timeLimit(.minutes(1)))
    func residencyIsMeasured() throws {
        let shaper = TrafficShaper(
            configuration: TrafficShaperConfiguration(
                parameters: TrafficShapeParameters(maxPacketRate: 200),   // 5 ms apart
                queueCapacity: 64
            )
        ) { _ in }

        // More than CMAX (16): the first 16 leave on the initial burst and only the remainder
        // has to wait for tokens, which is what makes residency observable at all.
        for value in UInt8(0)..<UInt8(24) {
            #expect(shaper.enqueue(Data([value]), payloadOctets: 1))
        }
        #expect(shaper.stop(drain: true, timeout: 5))

        let snapshot = shaper.snapshot()
        #expect(snapshot.packetsSent == 24)
        // CMAX packets leave immediately; the rest wait for tokens, so the last ones must show
        // a residency well above zero.
        #expect(snapshot.maximumQueueResidencyNanoseconds > 1_000_000,
                "the tail of the batch waited milliseconds, not nanoseconds")
        #expect(snapshot.meanQueueResidencyNanoseconds > 0)
        #expect(snapshot.meanQueueResidencyNanoseconds
                <= snapshot.maximumQueueResidencyNanoseconds)
    }

    @Test("Pacing error stays bounded by the busy-wait", .timeLimit(.minutes(1)))
    func pacingErrorIsSmall() {
        let shaper = TrafficShaper(
            configuration: TrafficShaperConfiguration(
                parameters: TrafficShapeParameters(maxPacketRate: 2_000),
                queueCapacity: 64,
                spinThresholdNanoseconds: 50_000
            )
        ) { _ in }

        for value in UInt8(0)..<UInt8(20) {
            #expect(shaper.enqueue(Data([value]), payloadOctets: 1))
        }
        #expect(shaper.stop(drain: true, timeout: 5))

        // Distinct from residency: this one says whether the thread hit its own deadlines.
        #expect(shaper.snapshot().maximumPacingErrorNanoseconds < 10_000_000)
    }
}

@Suite("Advertised bitrate (TR-10-7 §11)")
struct AdvertisedBitrateTests {

    /// "The bit rate shall include the whole of each IP packet, i.e. IP headers and payload."
    /// The coded bitrate alone leaves out 40 bytes per packet, which at these packet rates is
    /// not a rounding error.
    @Test("b=AS adds the IP, UDP and RTP headers at MaxRate")
    func headersAreIncluded() {
        let parameters = TrafficShapeParameters(maxPacketRate: 1_193)
        let advertised = parameters.advertisedBitrateKbps(codedBitrateKbps: 8_000)

        // 1193 pps x 40 bytes x 8 = 381.8 kbit/s of headers.
        #expect(advertised == 8_382)
        #expect(advertised > 8_000, "never below the coded rate")
    }

    @Test("The header allowance scales with the packet rate", arguments: [
        (600.0, 8_192), (1_193.0, 8_382), (2_400.0, 8_768),
    ])
    func scalesWithPacketRate(packetRate: Double, expected: Int) {
        #expect(TrafficShapeParameters(maxPacketRate: packetRate)
            .advertisedBitrateKbps(codedBitrateKbps: 8_000) == expected)
    }

    @Test("The header size matches IPv4 plus UDP plus the fixed RTP header")
    func headerSize() {
        #expect(TrafficShapeParameters.ipUDPRTPHeaderBytes == 40)
        #expect(TrafficShapeParameters.ipUDPRTPHeaderBytes == 20 + 8 + RTPHeader.size)
    }

    @Test("A zero header allowance reduces to the coded rate")
    func noHeaders() {
        #expect(TrafficShapeParameters(maxPacketRate: 1_000)
            .advertisedBitrateKbps(codedBitrateKbps: 8_000, headerBytesPerPacket: 0) == 8_000)
    }
}

@Suite("Traffic shaper shutdown")
struct TrafficShaperShutdownTests {

    /// Completion used to be signalled through a one-shot semaphore, so a second caller waited
    /// out its whole timeout and then reported failure on a shaper that had stopped cleanly.
    @Test("stop is idempotent and does not stall a second caller", .timeLimit(.minutes(1)))
    func repeatedStop() {
        let shaper = TrafficShaper(
            configuration: TrafficShaperConfiguration(
                parameters: TrafficShapeParameters(maxPacketRate: 100_000),
                queueCapacity: 16
            )
        ) { _ in }

        #expect(shaper.enqueue(Data([1]), payloadOctets: 1))
        #expect(shaper.stop(drain: true, timeout: 5))

        let start = Date()
        #expect(shaper.stop(drain: true, timeout: 5), "a second stop still reports success")
        #expect(shaper.stop(drain: false, timeout: 5))
        #expect(Date().timeIntervalSince(start) < 1.0, "and returns immediately")
        #expect(shaper.snapshot().state == .stopped)
    }
}
