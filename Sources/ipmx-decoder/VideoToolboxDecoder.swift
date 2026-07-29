import CoreMedia
import CoreVideo
import Foundation
import IPMXCore
import VideoToolbox

/// Hardware H.264 decode through VideoToolbox.
///
/// Unlike the encode side, there is no reason to avoid VideoToolbox here: decoding has no
/// HRD-signalling requirement to satisfy, and the M-series media engine does this for
/// essentially no CPU. The session is rebuilt whenever the parameter sets change.
final class VideoToolboxDecoder {
    typealias FrameHandler = (CVImageBuffer, CMTime) -> Void

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var sawKeyframe = false
    private let handler: FrameHandler

    private(set) var framesDecoded: UInt64 = 0
    private(set) var framesDropped: UInt64 = 0

    init(handler: @escaping FrameHandler) {
        self.handler = handler
    }

    deinit {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Decodes one access unit. Parameter sets are absorbed into the format description;
    /// everything before the first IDR is discarded, since VideoToolbox cannot start on a
    /// non-recovery point.
    func decode(accessUnit units: [NALUnit], timestamp: UInt32) {
        var parameterSetsChanged = false
        var payload: [NALUnit] = []

        for unit in units {
            switch unit.typeValue {
            case H264NALType.sps.rawValue:
                if sps != unit.bytes { sps = unit.bytes; parameterSetsChanged = true }
            case H264NALType.pps.rawValue:
                if pps != unit.bytes { pps = unit.bytes; parameterSetsChanged = true }
            case H264NALType.aud.rawValue, H264NALType.filler.rawValue:
                break                                    // not carried in AVCC sample data
            default:
                payload.append(unit)
                if unit.isKeyframe { sawKeyframe = true }
            }
        }

        if parameterSetsChanged {
            rebuildSession()
        }
        guard sawKeyframe, let session, let formatDescription, !payload.isEmpty else {
            if !payload.isEmpty { framesDropped += 1 }
            return
        }

        let sampleData = AnnexB.lengthPrefixed(payload)
        guard let sampleBuffer = makeSampleBuffer(data: sampleData,
                                                  formatDescription: formatDescription,
                                                  timestamp: timestamp) else { return }

        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: flags, infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, presentationTime, _ in
            guard let self else { return }
            guard status == noErr, let imageBuffer else {
                self.framesDropped += 1
                Log.debug("decode callback status \(status)")
                return
            }
            self.framesDecoded += 1
            self.handler(imageBuffer, presentationTime)
        }

        if status != noErr {
            framesDropped += 1
            Log.debug("VTDecompressionSessionDecodeFrame returned \(status)")
        }
    }

    private func rebuildSession() {
        guard let sps, let pps else { return }

        var newFormat: CMVideoFormatDescription?
        let created: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsBase = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return OSStatus(-1)
                }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,          // matches AnnexB.lengthPrefixed
                            formatDescriptionOut: &newFormat
                        )
                    }
                }
            }
        }

        guard created == noErr, let newFormat else {
            Log.error("could not build a format description from SPS/PPS (status \(created))")
            return
        }

        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: newFormat,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,                              // nil selects the block-based API
            decompressionSessionOut: &newSession
        )

        guard status == noErr, let newSession else {
            Log.error("VTDecompressionSessionCreate failed with status \(status)")
            return
        }

        session = newSession
        formatDescription = newFormat

        let dimensions = CMVideoFormatDescriptionGetDimensions(newFormat)
        Log.info("decoder ready: \(dimensions.width)x\(dimensions.height)")
    }

    private func makeSampleBuffer(data: Data,
                                  formatDescription: CMVideoFormatDescription,
                                  timestamp: UInt32) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        status = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!,
                                          blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0,
                                          dataLength: data.count)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        // The 90 kHz RTP timestamp is the media clock, so it maps straight onto CMTime.
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(timestamp), timescale: CMTimeScale(MediaClock.rate)),
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        return status == noErr ? sampleBuffer : nil
    }
}
