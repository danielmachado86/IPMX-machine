import CoreVideo
import Foundation
import IPMXCore
import VideoToolbox

/// Converts pixel buffers into the biplanar 4:2:0 the encoders expect.
///
/// ScreenCaptureKit hands us NV12 already, but a capture card usually does not: HDMI and SDI
/// bridges commonly present 4:2:2, either packed `2vuy` (UYVY) at 8 bits or `v210` at 10, and
/// the chroma has to be resampled vertically as well as repacked. There is no vImage entry
/// point for 4:2:2 to 4:2:0 — `VTPixelTransferSession` is the supported path on macOS and it
/// runs on the same hardware the codecs use.
///
/// Dropping 4:2:2 to 4:2:0 is lossy. It is what TR-10-15 §12 asks of a sender as a minimum,
/// and it is what the current encoder configuration is built around; a 4:2:2 profile would be
/// legal ("may support additional profiles") and better for a professional source.
final class PixelFormatConverter {
    private let session: VTPixelTransferSession
    private let pool: CVPixelBufferPool
    let destinationFormat: OSType

    init(width: Int, height: Int,
         destinationFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) throws {
        self.destinationFormat = destinationFormat

        var session: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                                  pixelTransferSessionOut: &session)
        guard status == noErr, let session else {
            throw EncoderError.open("VTPixelTransferSessionCreate failed with status \(status)")
        }
        self.session = session

        // Preserve the full picture rather than letterboxing, and use a good chroma filter:
        // this downsamples chroma vertically, so nearest-neighbour would be visible.
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode,
                             value: kVTScalingMode_Normal)
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DownsamplingMode,
                             value: kVTDownsamplingMode_Average)

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: destinationFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else {
            throw EncoderError.open("could not create a pixel buffer pool for the converter")
        }
        self.pool = pool
    }

    /// Returns the source untouched when it is already in the destination format, so the
    /// zero-conversion path stays zero-conversion.
    func convert(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        if CVPixelBufferGetPixelFormatType(source) == destinationFormat {
            return source
        }

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
              let destination else {
            throw EncoderError.encode("pixel buffer pool exhausted")
        }

        let status = VTPixelTransferSessionTransferImage(session, from: source, to: destination)
        guard status == noErr else {
            throw EncoderError.encode("VTPixelTransferSessionTransferImage failed with status \(status)")
        }
        return destination
    }

    static func fourCC(_ format: OSType) -> String {
        let bytes = [UInt8((format >> 24) & 0xFF), UInt8((format >> 16) & 0xFF),
                     UInt8((format >> 8) & 0xFF), UInt8(format & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "0x\(String(format, radix: 16))"
    }
}
