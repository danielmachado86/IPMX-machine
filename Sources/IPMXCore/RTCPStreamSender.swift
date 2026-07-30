import Foundation

/// Emits RTCP Sender Reports carrying the IPMX Info Block.
///
/// TR-10-1 §8.7 puts these on the media UDP port plus one, which is why `MediaPort` refuses an
/// odd media port: it would land RTCP on an even port and collide with the next stream.
///
/// The report goes out *before* the first media packet of its frame (TR-10-15 §15), and a frame
/// the encoder skipped still gets its report — the schedule is what a receiver derives its
/// playout from, so a gap in it is worse than a gap in the video.
public final class RTCPStreamSender {
    private let socket: UDPSender
    public let ssrc: UInt32
    public let timestampReferenceClock: String
    public let mediaClock: String

    private var blockVersion: UInt8 = 0
    private var lastFingerprint: Data?

    public private(set) var reportsSent: UInt64 = 0
    public var currentBlockVersion: UInt8 { blockVersion }

    /// - Parameters:
    ///   - timestampReferenceClock: the `a=ts-refclk` value, e.g. `localmac`.
    ///   - mediaClock: the `a=mediaclk` value, e.g. `direct=0`.
    public init(socket: UDPSender,
                ssrc: UInt32,
                timestampReferenceClock: String,
                mediaClock: String) {
        self.socket = socket
        self.ssrc = ssrc
        self.timestampReferenceClock = timestampReferenceClock
        self.mediaClock = mediaClock
    }

    /// Builds and sends one Sender Report. Returns the bytes put on the wire, for logging.
    @discardableResult
    public func send(rtpTimestamp: UInt32,
                     timestamp: PTPTimestamp,
                     packetCount: UInt32,
                     octetCount: UInt32,
                     mediaInfoBlocks: [MediaInfoBlock]) throws -> Data {
        var infoBlock = IPMXInfoBlock(blockVersion: blockVersion,
                                      timestampReferenceClock: timestampReferenceClock,
                                      mediaClock: mediaClock,
                                      mediaInfoBlocks: mediaInfoBlocks)

        // "An 8-bit counter that increments whenever the content of the IPMX Info Block
        // changes." In practice it changes once, when the parameter sets first show up.
        let fingerprint = infoBlock.contentFingerprint()
        if let previous = lastFingerprint, previous != fingerprint {
            blockVersion = blockVersion &+ 1
            infoBlock.blockVersion = blockVersion
        }
        lastFingerprint = fingerprint

        let report = RTCPSenderReport(ssrc: ssrc,
                                      timestamp: timestamp,
                                      rtpTimestamp: rtpTimestamp,
                                      packetCount: packetCount,
                                      octetCount: octetCount,
                                      infoBlock: infoBlock)
        let datagram = report.serialized()
        try socket.send(datagram)
        reportsSent += 1
        return datagram
    }
}
