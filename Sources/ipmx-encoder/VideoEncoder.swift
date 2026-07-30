import CoreVideo
import Foundation
import IPMXCore

/// What the capture loop needs from an encoder, independent of codec.
protocol VideoEncoder: AnyObject {
    var codec: VideoCodec { get }

    /// Encodes one NV12 pixel buffer. Returns the NAL units of the resulting access unit,
    /// or an empty array when the encoder produced no output for this input.
    func encode(pixelBuffer: CVPixelBuffer, presentationTimestamp: Int64) throws -> [NALUnit]

    /// Becomes non-nil once the encoder has emitted its parameter sets, which is what the
    /// SDP needs before it can be written.
    var formatParameters: VideoFormatParameters? { get }
}

struct EncoderConfiguration {
    var width: Int
    var height: Int
    var frameRate: Int
    var bitrateKbps: Int
    /// TR-10-15 §11 requires a random access point at least every 5 s in both parts.
    /// 2 s is friendlier to a receiver that joins late.
    var keyframeIntervalSeconds: Int = 2
    var preset: String
    var profile: String
    /// Emit the HRD signalling plus the Buffering Period / Picture Timing SEI that
    /// TR-10-15 §10 mandates.
    ///
    /// On by default: TR-10-7 §10 switches off the ST 2110 Virtual Receiver Buffer Model for
    /// compressed video and leaves buffer management to the codec spec, and TR-10-15 §10 fills
    /// that gap with the HRD schedules. Without it the stream still decodes but carries no
    /// buffering contract at all, which is what a receiver needs to derive its playout time.
    /// Measured cost at 1080p60/8 Mbit/s: 6.2 kbps of SEI, about 0.08%.
    var enableHRD: Bool = true
}

enum EncoderError: Error, CustomStringConvertible {
    case parameterSetup(String)
    case open(String)
    case encode(String)
    case unexpectedPixelFormat

    var description: String {
        switch self {
        case .parameterSetup(let detail): return "encoder parameter setup failed: \(detail)"
        case .open(let detail):           return "could not open the encoder: \(detail)"
        case .encode(let detail):         return "encode failed: \(detail)"
        case .unexpectedPixelFormat:      return "expected a biplanar 4:2:0 (NV12) pixel buffer"
        }
    }
}
