import CoreVideo
import Foundation
import IPMXCore

/// Where the pictures come from.
///
/// The two kinds differ in more than plumbing, and the difference is normative:
///
/// - `screen` is a synthetic source. Its media clock *is* our Internal Clock, so TR-10-1 §10.5
///   signals `mediaclk:direct=0`, and TR-10-9 §10 supplies the raster fields we cannot measure.
/// - `capture` is a converted baseband signal. Its media clock belongs to whatever is plugged
///   into the HDMI/SDI input and is asynchronous to ours, so §10.5 signals `mediaclk:sender`
///   and the frame timing has to follow the device rather than a local timer.
enum VideoSourceKind: String, CaseIterable {
    case screen
    case capture

    init?(argument: String) {
        switch argument.lowercased() {
        case "screen", "display", "pantalla": self = .screen
        case "capture", "device", "hdmi", "sdi": self = .capture
        default: return nil
        }
    }

    /// TR-10-1 §10.5. The rule itself lives in IPMXCore; this only picks a side.
    var mediaClockRelationship: MediaClockRelationship {
        switch self {
        case .screen:  return .direct()
        case .capture: return .sender      // Async Media at the input of a Sender
        }
    }

    /// Whether the source's own clock decides when a frame exists.
    var cadenceMode: FrameCadence.Mode {
        switch self {
        case .screen:  return .timerDriven
        case .capture: return .sourceDriven
        }
    }

    var description: String {
        switch self {
        case .screen:  return "screen capture (synthetic, synchronous to the Internal Clock)"
        case .capture: return "capture device (baseband conversion, asynchronous media)"
        }
    }
}

/// Anything that can be started, stopped, and hands pixel buffers to the cadence.
protocol VideoSource: AnyObject {
    func start() async throws
    func stop() async
}
