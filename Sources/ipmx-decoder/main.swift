import AppKit
import CoreMedia
import Dispatch
import Foundation
import IPMXCore

// ipmx-decoder — Phase 0
// UDP multicast -> RFC 6184/7798 -> VideoToolbox -> AVSampleBufferDisplayLayer.

let options = CommandLineOptions()

if options.flag("help") {
    print("""
    ipmx-decoder — IPMX Phase 0 receiver

      --codec <name>   h264 | h265, ignored when --sdp says otherwise (default h264)
      --group <ip>     multicast group or local address to bind (default 239.10.10.10)
      --port <n>       UDP port                                 (default 50000)
      --iface <ip>     interface to join the group on           (default: first non-loopback IPv4)
      --sdp <path>     read transport, codec and parameter sets from an SDP
      --width <n>      initial window width                     (default 1280)
      --height <n>     initial window height                    (default 720)
      --verbose
    """)
    exit(0)
}

Log.verbose = options.flag("verbose")

let codecName = options.string("codec", default: "h264")
guard var codec = VideoCodec(argument: codecName) else {
    Log.error("unknown codec '\(codecName)'; expected h264 or h265")
    exit(1)
}

var group = options.string("group", default: "239.10.10.10")
var port = options.uint16("port", default: 50000)
var seedParameterSets: [NALUnit] = []

// An SDP on the command line wins over the individual flags: it is what a real IS-05
// connection would hand us, so exercising that path early keeps Phase 4 honest.
if let sdpPath = options.optionalString("sdp"),
   let text = try? String(contentsOfFile: sdpPath, encoding: .utf8) {
    let transport = SDPDescription.parseTransport(text)
    if let address = transport.address { group = address }
    if let sdpPort = transport.port { port = sdpPort }
    if let sdpCodec = transport.codec { codec = sdpCodec }
    seedParameterSets = transport.parameterSets
    Log.info("loaded transport from \(sdpPath): \(codec.rawValue) on \(group):\(port)")
}

let interface = options.optionalString("iface") ?? IPv4.defaultInterfaceAddress()

let application = NSApplication.shared
application.setActivationPolicy(.regular)

let player = PlayerWindow(
    width: options.int("width", default: 1280),
    height: options.int("height", default: 720),
    title: "IPMX Phase 0 — waiting for \(codec.rawValue) on \(group):\(port)"
)

let decoder = VideoToolboxDecoder(codec: codec) { imageBuffer, presentationTime in
    DispatchQueue.main.async {
        player.present(imageBuffer: imageBuffer, presentationTime: presentationTime)
    }
}

// Seeding from the SDP lets the decoder build its format description before the first
// in-band parameter sets arrive. With repeat-headers on the sender it rarely matters, but it
// is the behaviour IS-05 implies.
if !seedParameterSets.isEmpty {
    decoder.decode(accessUnit: seedParameterSets, timestamp: 0)
    Log.info("seeded \(seedParameterSets.count) parameter set(s) from the SDP")
}

let receiver: UDPReceiver
do {
    receiver = try UDPReceiver(group: group, port: port, interface: interface)
    Log.info("listening on \(group):\(port) via \(interface)")
    Log.debug("payload format: \(codec.specReference)")
    Log.debug("SO_RCVBUF = \(receiver.actualReceiveBufferBytes()) bytes")
} catch {
    Log.error("\(error)")
    exit(1)
}

let activeCodec = codec
let networkThread = Thread {
    let depacketizer = VideoDepacketizer(codec: activeCodec)
    var lastReport = MonotonicClock.now()
    var packets: UInt64 = 0

    while true {
        guard let datagram = receiver.receive() else { continue }
        packets += 1

        guard let (header, payload) = RTPHeader.parse(datagram) else {
            Log.debug("dropping a datagram that is not RTP (\(datagram.count) bytes)")
            continue
        }

        if let accessUnit = depacketizer.push(payload: payload,
                                              timestamp: header.timestamp,
                                              marker: header.marker,
                                              sequence: header.sequenceNumber) {
            if accessUnit.corrupt {
                Log.debug("access unit at ts \(accessUnit.timestamp) is incomplete")
            }
            decoder.decode(accessUnit: accessUnit.units, timestamp: accessUnit.timestamp)
        }

        let now = MonotonicClock.now()
        if now - lastReport >= 1.0 {
            lastReport = now
            let summary = String(format: "%llu decoded, %llu dropped, %llu lost pkts, %llu pkts in",
                                 decoder.framesDecoded, decoder.framesDropped,
                                 depacketizer.lostPackets, packets)
            Log.info(summary)
            DispatchQueue.main.async {
                player.updateTitle("IPMX Phase 0 \(activeCodec.rawValue) — \(summary)")
            }
        }
    }
}
networkThread.name = "tv.vsf.ipmx.receive"
networkThread.qualityOfService = .userInteractive
networkThread.start()

application.activate(ignoringOtherApps: true)
application.run()
