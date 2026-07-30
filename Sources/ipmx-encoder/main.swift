import AVFoundation
import CoreMedia
import Dispatch
import Foundation
import IPMXCore

// ipmx-encoder — Phases 0 to 3
// ScreenCaptureKit -> x264/x265 -> RFC 6184/7798 -> UDP, with RTCP Sender Reports carrying
// the IPMX Info Block and CINST/CMAX traffic shaping. No NMOS, no PTP.

let options = CommandLineOptions()

if options.flag("help") {
    print("""
    ipmx-encoder — IPMX sender

      --source <kind>      screen | capture           (default screen)
      --device <sel>       capture device by index, name substring or unique id
      --list-devices       print the capture devices and their formats, then exit
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
      --display <index>    display to capture, screen source only (default 0)
      --preset <name>      x264/x265 preset           (default veryfast)
      --profile <name>     h264: high | main, h265: main
      --sdp <path>         where to write the SDP     (default sdp/stream.sdp)
      --dump <path>        also write the Annex B elementary stream
      --mtu <bytes>        max RTP payload            (default 1400)
      --max-packet-rate <pps>
                           TR-10-7 MaxRate; default derives conservatively from bitrate and MTU
      --no-hrd             drop the HRD signalling and its SEI. Non-conformant, debugging only
      --no-rtcp            do not send Sender Reports. Non-conformant, debugging only
      --no-shaping         send each frame as a burst. Non-conformant, debugging only
      --verbose
    """)
    exit(0)
}

Log.verbose = options.flag("verbose")

if options.flag("list-devices") {
    print(CaptureDeviceSource.describeDevices())
    exit(0)
}

let sourceName = options.string("source", default: "screen")
guard let sourceKind = VideoSourceKind(argument: sourceName) else {
    Log.error("unknown source '\(sourceName)'; expected screen or capture")
    exit(1)
}

// Resolved here rather than where the source is built, so a bad selector fails before the
// encoder and the sockets are brought up.
let captureDevice: AVCaptureDevice?
if sourceKind == .capture {
    let selector = options.optionalString("device")
    guard let device = CaptureDeviceSource.device(matching: selector) else {
        Log.error("no capture device matches '\(selector ?? "")'")
        Log.error("available devices:\n\(CaptureDeviceSource.describeDevices())")
        exit(1)
    }
    captureDevice = device
} else {
    captureDevice = nil
}

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
guard bitrateKbps > 0 else {
    Log.error("bitrate must be positive")
    exit(1)
}
let gopSeconds = min(options.int("gop", default: 2), 5)   // TR-10-15 §11: RAP at least every 5 s
let destination = options.string("dest", default: "239.10.10.10")
let port = options.uint16("port", default: 50000)
let interface = options.optionalString("iface") ?? IPv4.defaultInterfaceAddress()
let sdpPath = options.string("sdp", default: "sdp/stream.sdp")
let mtu = options.int("mtu", default: 1400)
guard mtu > 4 else {
    Log.error("mtu must leave room for the fragmentation headers")
    exit(1)
}
let rtcpEnabled = !options.flag("no-rtcp")
let shapingEnabled = !options.flag("no-shaping")

let estimatedMaxPacketRate = TrafficShapeParameters.estimatedMaxPacketRate(
    maxBitrateKbps: bitrateKbps,
    maxRTPPayloadBytes: mtu,
    frameRate: frameRate
)
let maxPacketRate = Double(options.int("max-packet-rate",
                                       default: Int(estimatedMaxPacketRate)))
guard maxPacketRate > 0 else {
    Log.error("max-packet-rate must be positive")
    exit(1)
}
let trafficShapeParameters = TrafficShapeParameters(maxPacketRate: maxPacketRate)
let trafficShapeConfiguration = shapingEnabled
    ? TrafficShaperConfiguration(parameters: trafficShapeParameters)
    : nil

do {
    for advisory in try MediaPort.validate(port) {
        Log.info("warning: \(advisory)")
    }
} catch {
    Log.error("\(error)")
    exit(1)
}

// The clock signalling, shared by the SDP and the IPMX Info Block so the two agree.
// TR-10-1 §10.5: a capture card is Async Media at the input of a Sender, so its media clock is
// asynchronous to our Internal Clock and must be signalled as `sender`, not `direct=0`.
let timestampReferenceClock = "localmac"
let mediaClockSignalling = sourceKind.mediaClockRelationship.sdpValue

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
                             packetizer: VideoPacketizer(codec: codec, maxPayloadSize: mtu),
                             trafficShape: trafficShapeConfiguration)

    if let shape = sender.trafficShapeSnapshot {
        Log.info("traffic shaping: MaxRate \(Int(maxPacketRate)) packets/s, "
               + "CMAX \(trafficShapeParameters.cmax), \(shape.state)")
        if case .bestEffort = shape.state {
            Log.info("warning: the traffic shaper could not obtain Mach real-time scheduling")
        }
    } else {
        Log.info("warning: traffic shaping disabled, so this stream does not conform to TR-10-7 §10")
    }

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

// A capture card *is* a baseband conversion, so TR-10-1 §10.2 applies and the sender is
// supposed to report the measured pixel clock and the real total raster, within 150 ppm.
// UVC delivers frames, not blanking intervals, so we cannot measure either. Say so out loud
// rather than leave the gap buried in a comment: it needs a device SDK that exposes signal
// timing, which is the main thing a DeckLink or AJA would buy over a Magewell.
if sourceKind == .capture {
    Log.info("warning: reporting htotal, vtotal and measuredpixclk per TR-10-9 §10, but a "
           + "baseband source should measure them per TR-10-1 §10.2 — UVC does not expose the raster")
}

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
        formatParameters: formatParameters,
        timestampReferenceClock: timestampReferenceClock,
        mediaClock: mediaClockSignalling
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
let cadence = FrameCadence(mode: sourceKind.cadenceMode, frameRate: frameRate) { tick in
    let pixelBuffer = tick.pixelBuffer

    // Screen capture runs on our own clock, so the timestamp is exact arithmetic on the frame
    // index. A capture card does not: `mediaclk:sender` means the media clock is the sender's
    // own and unrelated to any reference, so the timestamp has to follow when the frame really
    // arrived, otherwise the two clocks drift apart over a long run.
    let rtpTimestamp: UInt32
    switch sourceKind {
    case .screen:
        rtpTimestamp = mediaClock.timestamp(forFrameIndex: tick.frameIndex,
                                            ticksPerFrame: ticksPerFrame)
    case .capture:
        rtpTimestamp = mediaClock.timestamp(forPresentationTime: tick.presentationTime)
    }

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
                              packetCount: UInt32(truncatingIfNeeded: sender.packetsTransmitted),
                              octetCount: UInt32(truncatingIfNeeded: sender.payloadBytesTransmitted),
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
            let shape = sender.trafficShapeSnapshot
            let wireBytes = shape?.bytesSent ?? sender.bytesSent
            let mbps = Double(wireBytes) * 8.0 / elapsed / 1_000_000.0
            let queue = shape?.queuedPackets ?? 0
            // Queue residency is the overload signal: it grows without bound when MaxRate is
            // below what the encoder produces. Dropped access units are the consequence.
            let residencyMs = Double(shape?.meanQueueResidencyNanoseconds ?? 0) / 1_000_000.0
            Log.info(String(format: "%llu frames (%llu repeated), %llu packets, %llu reports, "
                          + "%d queued, %.1f ms in queue, %llu dropped AU, %.2f Mbit/s",
                            total, cadence.repeatedFrames, sender.packetsTransmitted,
                            reporter?.reportsSent ?? 0, queue, residencyMs,
                            sender.droppedAccessUnits, mbps))
        }
    } catch {
        Log.error("\(error)")
    }
}

// Both sources only fill the slot; FrameCadence decides what a frame is and when.
let source: VideoSource
switch sourceKind {
case .screen:
    source = ScreenSource(
        configuration: .init(width: width, height: height, frameRate: frameRate,
                             displayIndex: options.int("display", default: 0))
    ) { pixelBuffer, presentationTime in
        cadence.submit(pixelBuffer, presentationTime: CMTimeGetSeconds(presentationTime))
    }

case .capture:
    source = CaptureDeviceSource(
        device: captureDevice!,
        configuration: .init(width: width, height: height, frameRate: frameRate)
    ) { pixelBuffer, presentationTime in
        cadence.submit(pixelBuffer, presentationTime: presentationTime)
    }
}

Log.info("source: \(sourceKind.description)")

// MARK: - Run

let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    Log.info("stopping")
    cadence.stop()
    Task {
        await source.stop()
        let drained = sender.shutdown(drain: true)
        if !drained {
            Log.error("traffic shaper did not drain within 5 seconds")
        }
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
        _ = sender.shutdown(drain: false)
        if sourceKind == .screen {
            Log.error("check System Settings > Privacy & Security > Screen Recording for your terminal app")
        }
        exit(1)
    }
}

dispatchMain()
