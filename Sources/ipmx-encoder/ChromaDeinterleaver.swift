import Accelerate
import CoreVideo
import Foundation

/// Splits the interleaved CbCr plane of an NV12 buffer into two planar chroma planes.
///
/// Needed only for x265. libx264 accepts `X264_CSP_NV12` directly, which is why the H.264
/// path has no colour conversion at all; x265 does not — its header lists NV12 but puts it
/// past `X265_CSP_COUNT`, with the comment "will eventually be supported as input pictures".
/// So HEVC needs a real deinterleave, and ScreenCaptureKit cannot hand us planar 4:2:0
/// either (it only offers BGRA and the two biplanar YUV formats).
///
/// The luma plane is passed straight through to the encoder by pointer, so only chroma is
/// touched. `vImageConvert_ChunkyToPlanar8` is the NEON-accelerated path for exactly this
/// two-channel split.
final class ChromaDeinterleaver {
    let chromaWidth: Int
    let chromaHeight: Int

    private let cb: UnsafeMutablePointer<UInt8>
    private let cr: UnsafeMutablePointer<UInt8>

    /// Planar output for one frame. Valid until the next `deinterleave` call.
    struct Planes {
        var luma: UnsafeMutableRawPointer
        var lumaStride: Int
        var cb: UnsafeMutableRawPointer
        var cr: UnsafeMutableRawPointer
        var chromaStride: Int
    }

    init(width: Int, height: Int) {
        chromaWidth = (width + 1) / 2
        chromaHeight = (height + 1) / 2
        let count = chromaWidth * chromaHeight
        cb = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        cr = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        cb.initialize(repeating: 128, count: count)
        cr.initialize(repeating: 128, count: count)
    }

    deinit {
        cb.deallocate()
        cr.deallocate()
    }

    /// The pixel buffer must already be locked by the caller.
    func deinterleave(pixelBuffer: CVPixelBuffer) throws -> Planes {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            throw EncoderError.unexpectedPixelFormat
        }

        let sourceRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        var cbBuffer = vImage_Buffer(data: cb,
                                     height: vImagePixelCount(chromaHeight),
                                     width: vImagePixelCount(chromaWidth),
                                     rowBytes: chromaWidth)
        var crBuffer = vImage_Buffer(data: cr,
                                     height: vImagePixelCount(chromaHeight),
                                     width: vImagePixelCount(chromaWidth),
                                     rowBytes: chromaWidth)

        let error: vImage_Error = withUnsafePointer(to: &cbBuffer) { cbPointer in
            withUnsafePointer(to: &crBuffer) { crPointer in
                var destinations: [UnsafePointer<vImage_Buffer>?] = [cbPointer, crPointer]
                // Cb sits at even offsets in the interleaved plane, Cr at odd ones.
                var sources: [UnsafeRawPointer?] = [
                    UnsafeRawPointer(chroma),
                    UnsafeRawPointer(chroma).advanced(by: 1),
                ]
                return vImageConvert_ChunkyToPlanar8(
                    &sources,
                    &destinations,
                    2,                                   // channelCount
                    2,                                   // srcStrideBytes: CbCr are interleaved
                    vImagePixelCount(chromaWidth),
                    vImagePixelCount(chromaHeight),
                    sourceRowBytes,
                    vImage_Flags(kvImageDoNotTile)
                )
            }
        }

        guard error == kvImageNoError else {
            throw EncoderError.encode("vImageConvert_ChunkyToPlanar8 returned \(error)")
        }

        return Planes(luma: luma,
                      lumaStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
                      cb: UnsafeMutableRawPointer(cb),
                      cr: UnsafeMutableRawPointer(cr),
                      chromaStride: chromaWidth)
    }
}
