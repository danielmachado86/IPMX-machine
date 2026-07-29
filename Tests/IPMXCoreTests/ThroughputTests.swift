import XCTest
@testable import IPMXCore

/// Throughput budgets for the packet path.
///
/// These stay on XCTest deliberately: swift-testing has no performance-measurement API, so
/// `measure` is still the only way to get baselines recorded and regressions flagged. The
/// behavioural suites next door are all swift-testing.
///
/// Why this matters beyond tidiness: Phase 3 puts a real-time thread in charge of pacing to
/// CINST/CMAX (TR-10-7 §10). That thread cannot afford to be doing meaningful work per packet,
/// so the packetizer has to be orders of magnitude faster than the wire. 1080p60 at 50 Mbit/s
/// is roughly 4,500 packets/second — the assertions below leave a wide margin over that.
final class PacketizationThroughputTests: XCTestCase {

    /// A keyframe-sized NAL: 1080p intra frames land in this range at broadcast bitrates.
    private static let keyframeNAL = NALUnit(
        bytes: Data([0x65] + (0..<200_000).map { UInt8($0 % 251) })
    )

    private static let deltaNAL = NALUnit(
        bytes: Data([0x41] + (0..<20_000).map { UInt8($0 % 251) })
    )

    func testPacketizeKeyframeThroughput() {
        let packetizer = H264Packetizer(maxPayloadSize: 1400)
        measure {
            for _ in 0..<50 {
                _ = packetizer.packetize(accessUnit: [Self.keyframeNAL])
            }
        }
    }

    func testPacketizeDeltaFrameThroughput() {
        let packetizer = H264Packetizer(maxPayloadSize: 1400)
        measure {
            for _ in 0..<500 {
                _ = packetizer.packetize(accessUnit: [Self.deltaNAL])
            }
        }
    }

    func testRoundTripThroughput() {
        let packetizer = H264Packetizer(maxPayloadSize: 1400)
        let payloads = packetizer.packetize(accessUnit: [Self.deltaNAL])

        measure {
            for _ in 0..<200 {
                let depacketizer = H264Depacketizer()
                for (index, payload) in payloads.enumerated() {
                    _ = depacketizer.push(payload: payload,
                                          timestamp: 900_000,
                                          marker: index == payloads.count - 1,
                                          sequence: UInt16(truncatingIfNeeded: index))
                }
            }
        }
    }

    func testRTPHeaderSerializationThroughput() {
        measure {
            for index in 0..<50_000 {
                let header = RTPHeader(payloadType: 96,
                                       sequenceNumber: UInt16(truncatingIfNeeded: index),
                                       timestamp: 900_000,
                                       ssrc: 0x1234_5678,
                                       marker: index % 30 == 0)
                _ = header.serialized()
            }
        }
    }

    func testAnnexBSplitThroughput() {
        // A synthetic access unit shaped like what x264 hands us: SPS, PPS, then one slice.
        var stream = Data()
        stream.append(AnnexB.framed(NALUnit(bytes: Data([0x67, 0x64, 0x00, 0x28]))))
        stream.append(AnnexB.framed(NALUnit(bytes: Data([0x68, 0xCE, 0x3C, 0x80]))))
        stream.append(AnnexB.framed(Self.deltaNAL))

        measure {
            for _ in 0..<200 {
                _ = AnnexB.split(stream)
            }
        }
    }

    /// A hard ceiling rather than a baseline: packetizing one 1080p keyframe must stay far
    /// below a frame interval, otherwise the sender cannot keep up before shaping is even
    /// in the picture.
    func testKeyframePacketizationFitsWellInsideAFrameInterval() {
        let packetizer = H264Packetizer(maxPayloadSize: 1400)
        let iterations = 100

        let start = MonotonicClock.now()
        for _ in 0..<iterations {
            _ = packetizer.packetize(accessUnit: [Self.keyframeNAL])
        }
        let perCall = (MonotonicClock.now() - start) / Double(iterations)

        let frameInterval60fps = 1.0 / 60.0
        XCTAssertLessThan(perCall, frameInterval60fps / 4,
                          "packetizing a 200 KB keyframe took \(perCall * 1000) ms, more than a quarter of a 60 fps frame interval")
    }
}
