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
    /// Phase 1 switch: emit the HRD signalling and the Buffering Period / Picture Timing SEI
    /// that TR-10-15 §10 mandates.
    var enableHRD: Bool = false
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
