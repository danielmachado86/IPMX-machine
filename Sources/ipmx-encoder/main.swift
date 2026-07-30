import CoreMedia
import Dispatch
import Foundation
import IPMXCore

// ipmx-encoder — Phase 0
// ScreenCaptureKit -> x264/x265 -> RFC 6184/7798 -> UDP multicast.
// No RTCP, no NMOS, no PTP. The SDP is written to disk for the decoder to read.

let options = CommandLineOptions()

if options.flag("help") {
    print("""
    ipmx-encoder — IPMX Phase 0 sender

      --codec <name>       h264 | h265                (default h264)
      --dest <ip>          destination address        (default 239.10.10.10)
      --port <n>           destination UDP port, even and >5000 per TR-10-7 §7 (default 50000)
      --iface <ip>         local egress interface     (default: first non-loopback IPv4)
      --width <n>          capture width              (default 1920)
      --height <n>         capture height             (default 1080)
      --fps <n>            frame rate                 (default 60)
      --bitrate <kbps>     target bitrate             (default 8000)
      --gop <seconds>      keyframe interval, TR-10-15 §11 caps this at 5 (default 2)
      --display <index>    display to capture         (default 0)
      --preset <name>      x264/x265 preset           (default veryfast)
      --profile <name>     h264: high | main          (default high, per TR-10-15 Part 3 §12)
                           h265: main                 (default main, per TR-10-15 Part 2 §12)
      --sdp <path>         where to write the SDP     (default sdp/stream.sdp)
      --dump <path>        also write the Annex B elementary stream, for scripts/inspect-bitstream.py
      --mtu <bytes>        max RTP payload            (default 1400)
      --no-hrd             drop the HRD signalling and the Buffering Period / Picture Timing
                           SEI. Non-conformant per TR-10-15 §10 — debugging only
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
let bitrateKbps = options.int("bitrate", default: 8000)
let gopSeconds = min(options.int("gop", default: 2), 5)   // TR-10-15 §11: RAP at least every 5 s
let destination = options.string("dest", default: "239.10.10.10")
let port = options.uint16("port", default: 50000)
let interface = options.optionalString("iface") ?? IPv4.defaultInterfaceAddress()
let sdpPath = options.string("sdp", default: "sdp/stream.sdp")
let mtu = options.int("mtu", default: 1400)

if port % 2 != 0 {
    Log.info("warning: TR-10-7 §7 requires an even UDP destination port; \(port) is odd")
}
if port <= 5000 {
    Log.info("warning: TR-10-7 §7 recommends a UDP destination port above 5000")
}

// MARK: - Pipeline

let encoder: VideoEncoder
let sender: RTPStreamSender

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

    if options.flag("hrd") {
        Log.info("note: HRD signalling is on by default now; --hrd is redundant")
    }
    if options.flag("no-hrd") {
        Log.info("warning: HRD signalling disabled, so this stream does not conform to TR-10-15 §10")
    }

    switch codec {
    case .h264: encoder = try X264Encoder(configuration: configuration)
    case .h265: encoder = try X265Encoder(configuration: configuration)
    }

    let socket = try UDPSender(host: destination, port: port, interface: interface)
    sender = RTPStreamSender(socket: socket,
                             packetizer: VideoPacketizer(codec: codec, maxPayloadSize: mtu))
    Log.info("sending \(codec.rawValue) to \(socket.destinationDescription), SSRC 0x\(String(sender.ssrc, radix: 16))")
    Log.debug("payload format: \(codec.specReference)")
} catch {
    Log.error("\(error)")
    exit(1)
}

// Optional Annex B dump, so the bitstream can be checked against TR-10-15 §8 and §10 with
// scripts/inspect-bitstream.py. Writing it costs a file handle and nothing else.
let bitstreamDump: FileHandle? = options.optionalString("dump").flatMap { path in
    FileManager.default.createFile(atPath: path, contents: nil)
    let handle = FileHandle(forWritingAtPath: path)
    if handle != nil { Log.info("dumping the elementary stream to \(path)") }
    return handle
}

let clockOrigin = MonotonicClock.now()
let mediaClock = MediaClock(originSeconds: clockOrigin)

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

    let description = SDPDescription(
        originAddress: interface,
        destinationAddress: destination,
        port: port,
        payloadType: sender.payloadType,
        width: width,
        height: height,
        frameRate: frameRate,
        maxBitrateKbps: bitrateKbps,
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

let source = ScreenSource(
    configuration: .init(width: width, height: height, frameRate: frameRate,
                         displayIndex: options.int("display", default: 0))
) { pixelBuffer, presentationTime in
    let seconds = CMTimeGetSeconds(presentationTime)
    let rtpTimestamp = mediaClock.timestamp(forPresentationTime: seconds)

    do {
        let units = try encoder.encode(pixelBuffer: pixelBuffer,
                                       presentationTimestamp: Int64(rtpTimestamp))
        guard !units.isEmpty else { return }

        if let bitstreamDump {
            for unit in units { bitstreamDump.write(AnnexB.framed(unit)) }
        }

        // TR-10-7 §9: every packet of a progressive frame carries the same RTP timestamp.
        try sender.send(accessUnit: units, timestamp: rtpTimestamp)

        counters.lock.lock()
        counters.frames += 1
        let total = counters.frames
        counters.lock.unlock()

        writeSDPIfReady()

        if total % UInt64(frameRate) == 0 {
            let elapsed = MonotonicClock.now() - clockOrigin
            let mbps = Double(sender.bytesSent) * 8.0 / elapsed / 1_000_000.0
            Log.info(String(format: "%llu frames, %llu packets, %.2f Mbit/s on the wire",
                            total, sender.packetsSent, mbps))
        }
    } catch {
        Log.error("\(error)")
    }
}

// MARK: - Run

let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    Log.info("stopping")
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
    } catch {
        Log.error("capture failed to start: \(error)")
        Log.error("check System Settings > Privacy & Security > Screen Recording for your terminal app")
        exit(1)
    }
}

dispatchMain()
