import CoreMedia
import Dispatch
import Foundation
import IPMXCore

// ipmx-encoder — Phases 0 to 2
// ScreenCaptureKit -> x264/x265 -> RFC 6184/7798 -> UDP, with RTCP Sender Reports carrying
// the IPMX Info Block on the media port plus one. No NMOS, no PTP.

let options = CommandLineOptions()

if options.flag("help") {
    print("""
    ipmx-encoder — IPMX sender

      --codec <name>       h264 | h265                (default h264)
      --dest <ip>          destination address        (default 239.10.10.10)
      --port <n>           destination UDP port, even and >5000 per TR-10-7 §7 (default 50000)
                           RTCP goes to this port plus one
      --iface <ip>         local egress interface     (default: first non-loopback IPv4)
      --width <n>          capture width              (default 1920)
      --height <n>         capture height             (default 1080)
      --fps <n>            frame rate                 (default 60)
      --bitrate <kbps>     target bitrate             (default 8000)
      --gop <seconds>      keyframe interval, TR-10-15 §11 caps this at 5 (default 2)
      --display <index>    display to capture         (default 0)
      --preset <name>      x264/x265 preset           (default veryfast)
      --profile <name>     h264: high | main, h265: main
      --sdp <path>         where to write the SDP     (default sdp/stream.sdp)
      --dump <path>        also write the Annex B elementary stream
      --mtu <bytes>        max RTP payload            (default 1400)
      --no-hrd             drop the HRD signalling and its SEI. Non-conformant, debugging only
      --no-rtcp            do not send Sender Reports. Non-conformant, debugging only
      --verbose
    """)
    exit(0)
}

Log.verbose = options.flag("verbose")

let codecName = options.string("codec", default: "h264")
guard let codec = VideoCodec(argument: codecName) else {
    Log.error("unknown codec '\(codecName)'; expected h264 or h265")
    exit(1)
}

let width = options.int("width", default: 1920)
let height = options.int("height", default: 1080)
guard width % 2 == 0, height % 2 == 0 else {
    Log.error("width and height must be even for 4:2:0 chroma subsampling")
    exit(1)
}

let frameRate = options.int("fps", default: 60)
guard let ticksPerFrame = MediaClock.ticksPerFrame(frameRate: frameRate) else {
    Log.error("\(frameRate) fps does not divide the 90 kHz media clock evenly; "
            + "fractional rates are not supported yet")
    exit(1)
}

let bitrateKbps = options.int("bitrate", default: 8000)
let gopSeconds = min(options.int("gop", default: 2), 5)   // TR-10-15 §11: RAP at least every 5 s
let destination = options.string("dest", default: "239.10.10.10")
let port = options.uint16("port", default: 50000)
let interface = options.optionalString("iface") ?? IPv4.defaultInterfaceAddress()
let sdpPath = options.string("sdp", default: "sdp/stream.sdp")
let mtu = options.int("mtu", default: 1400)
let rtcpEnabled = !options.flag("no-rtcp")

do {
    for advisory in try MediaPort.validate(port) {
        Log.info("warning: \(advisory)")
    }
} catch {
    Log.error("\(error)")
    exit(1)
}

// The clock signalling that goes in both the SDP and the IPMX Info Block, so the two agree.
let timestampReferenceClock = "localmac"
let mediaClockSignalling = "direct=0"

// MARK: - Pipeline

let encoder: VideoEncoder
let sender: RTPStreamSender
let reporter: RTCPStreamSender?

do {
    let configuration = EncoderConfiguration(
        width: width,
        height: height,
        frameRate: frameRate,
        bitrateKbps: bitrateKbps,
        keyframeIntervalSeconds: gopSeconds,
        preset: options.string("preset", default: "veryfast"),
        profile: options.string("profile", default: codec == .h264 ? "high" : "main"),
        enableHRD: !options.flag("no-hrd")
    )

    if options.flag("no-hrd") {
        Log.info("warning: HRD signalling disabled, so this stream does not conform to TR-10-15 §10")
    }

    switch codec {
    case .h264: encoder = try X264Encoder(configuration: configuration)
    case .h265: encoder = try X265Encoder(configuration: configuration)
    }

    let mediaSocket = try UDPSender(host: destination, port: port, interface: interface)
    sender = RTPStreamSender(socket: mediaSocket,
                             packetizer: VideoPacketizer(codec: codec, maxPayloadSize: mtu))

    if rtcpEnabled {
        // TR-10-1 §8.7: same destination address, UDP port plus one.
        let rtcpSocket = try UDPSender(host: destination, port: port + 1, interface: interface)
        reporter = RTCPStreamSender(socket: rtcpSocket,
                                    ssrc: sender.ssrc,
                                    timestampReferenceClock: timestampReferenceClock,
                                    mediaClock: mediaClockSignalling)
        Log.info("RTCP Sender Reports to \(destination):\(port + 1)")
    } else {
        reporter = nil
        Log.info("warning: RTCP disabled, so this stream does not conform to TR-10-1 §8.7")
    }

    Log.info("sending \(codec.rawValue) to \(mediaSocket.destinationDescription), "
           + "SSRC 0x\(String(sender.ssrc, radix: 16))")
    Log.debug("payload format: \(codec.specReference)")
} catch {
    Log.error("\(error)")
    exit(1)
}

let bitstreamDump: FileHandle? = options.optionalString("dump").flatMap { path in
    FileManager.default.createFile(atPath: path, contents: nil)
    let handle = FileHandle(forWritingAtPath: path)
    if handle != nil { Log.info("dumping the elementary stream to \(path)") }
    return handle
}

let clockOrigin = MonotonicClock.now()
let mediaClock = MediaClock(originSeconds: clockOrigin)

/// The video Media Info Block never changes for a given configuration, so it is built once.
/// TR-10-9 §10 supplies the three fields a non-baseband sender cannot measure.
let videoInfoBlock = VideoMediaInfoBlock.nonBaseband(
    sampling: "YCbCr-4:2:0",
    bitDepth: 8,
    colorimetry: "BT709",
    width: UInt16(width),
    height: UInt16(height),
    frameRate: frameRate
)

final class Counters: @unchecked Sendable {
    var frames: UInt64 = 0
    var sdpWritten = false
    let lock = NSLock()
}
let counters = Counters()

func writeSDPIfReady() {
    counters.lock.lock()
    defer { counters.lock.unlock() }
    guard !counters.sdpWritten, let formatParameters = encoder.formatParameters else { return }

    // The same block the Sender Reports carry, so the fmtp line and the Media Info Block
    // cannot disagree — which is what TR-10-15 §16 requires.
    let description = SDPDescription(
        originAddress: interface,
        destinationAddress: destination,
        port: port,
        payloadType: sender.payloadType,
        maxBitrateKbps: bitrateKbps,
        video: videoInfoBlock,
        formatParameters: formatParameters
    )

    let url = URL(fileURLWithPath: sdpPath)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    do {
        try description.serialized().write(to: url, atomically: true, encoding: .utf8)
        counters.sdpWritten = true
        Log.info("wrote SDP to \(url.path)")
    } catch {
        Log.error("could not write SDP: \(error.localizedDescription)")
    }
}

// MARK: - Cadence

// Everything below runs on the cadence timer, one pass per nominal frame period.
let cadence = FrameCadence(frameRate: frameRate) { pixelBuffer, frameIndex in
    let rtpTimestamp = mediaClock.timestamp(forFrameIndex: frameIndex, ticksPerFrame: ticksPerFrame)

    // TR-10-15 §15: the Sender Report goes out before the first media packet of its frame, and
    // a frame the encoder skips still gets its report. Sending it here, before the encode,
    // satisfies both and keeps sender_reports_delay constant by construction.
    if let reporter {
        var blocks: [MediaInfoBlock] = [videoInfoBlock]
        if let parameters = encoder.formatParameters {
            blocks.append(makeCodecMediaInfoBlock(parameters))
        }
        do {
            try reporter.send(rtpTimestamp: rtpTimestamp,
                              timestamp: PTPTimestamp.now(),
                              packetCount: UInt32(truncatingIfNeeded: sender.packetsSent),
                              octetCount: UInt32(truncatingIfNeeded: sender.payloadBytesSent),
                              mediaInfoBlocks: blocks)
        } catch {
            Log.error("sender report failed: \(error)")
        }
    }

    do {
        let units = try encoder.encode(pixelBuffer: pixelBuffer,
                                       presentationTimestamp: Int64(rtpTimestamp))

        if !units.isEmpty {
            if let bitstreamDump {
                for unit in units { bitstreamDump.write(AnnexB.framed(unit)) }
            }
            // TR-10-7 §9: every packet of a progressive frame carries the same RTP timestamp.
            try sender.send(accessUnit: units, timestamp: rtpTimestamp)
        }

        counters.lock.lock()
        counters.frames += 1
        let total = counters.frames
        counters.lock.unlock()

        writeSDPIfReady()

        if total % UInt64(frameRate) == 0 {
            let elapsed = MonotonicClock.now() - clockOrigin
            let mbps = Double(sender.bytesSent) * 8.0 / elapsed / 1_000_000.0
            Log.info(String(format: "%llu frames (%llu repeated), %llu packets, %llu reports, %.2f Mbit/s",
                            total, cadence.repeatedFrames, sender.packetsSent,
                            reporter?.reportsSent ?? 0, mbps))
        }
    } catch {
        Log.error("\(error)")
    }
}

let source = ScreenSource(
    configuration: .init(width: width, height: height, frameRate: frameRate,
                         displayIndex: options.int("display", default: 0))
) { pixelBuffer, _ in
    // Capture only fills the slot; the cadence timer decides when to encode. See FrameCadence
    // for why this indirection exists.
    cadence.submit(pixelBuffer)
}

// MARK: - Run

let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    Log.info("stopping")
    cadence.stop()
    Task {
        await source.stop()
        exit(0)
    }
}
interrupt.resume()
signal(SIGINT, SIG_IGN)

Task {
    do {
        try await source.start()
        cadence.start()
    } catch {
        Log.error("capture failed to start: \(error)")
        Log.error("check System Settings > Privacy & Security > Screen Recording for your terminal app")
        exit(1)
    }
}

dispatchMain()
