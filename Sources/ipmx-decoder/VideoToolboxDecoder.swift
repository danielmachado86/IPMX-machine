import CoreMedia
import CoreVideo
import Foundation
import IPMXCore
import VideoToolbox

/// Hardware H.264 / H.265 decode through VideoToolbox.
///
/// Unlike the encode side, there is no reason to avoid VideoToolbox here: decoding has no
/// HRD-signalling requirement to satisfy, and the M-series media engine does this for
/// essentially no CPU. The session is rebuilt whenever the parameter sets change.
final class VideoToolboxDecoder {
    typealias FrameHandler = (CVImageBuffer, CMTime) -> Void

    let codec: VideoCodec

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [UInt8: Data] = [:]
    private var sawKeyframe = false
    private let handler: FrameHandler

    private(set) var framesDecoded: UInt64 = 0
    private(set) var framesDropped: UInt64 = 0

    /// The order VideoToolbox expects. H.265 needs all three; H.264 only the two.
    private var requiredParameterSetTypes: [UInt8] {
        switch codec {
        case .h264: return [H264NALType.sps.rawValue, H264NALType.pps.rawValue]
        case .h265: return [H265NALType.vps.rawValue, H265NALType.sps.rawValue, H265NALType.pps.rawValue]
        }
    }

    init(codec: VideoCodec, handler: @escaping FrameHandler) {
        self.codec = codec
        self.handler = handler
    }

    deinit {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Decodes one access unit. Parameter sets are absorbed into the format description;
    /// everything before the first random access point is discarded, since VideoToolbox
    /// cannot start mid-GOP.
    func decode(accessUnit units: [NALUnit], timestamp: UInt32) {
        var parameterSetsChanged = false
        var payload: [NALUnit] = []

        for unit in units {
            guard unit.codec == codec else { continue }

            if unit.isParameterSet {
                if parameterSets[unit.typeValue] != unit.bytes {
                    parameterSets[unit.typeValue] = unit.bytes
                    parameterSetsChanged = true
                }
            } else if unit.isDiscardableFromSampleData {
                continue                                  // AUD and filler stay out of the sample
            } else {
                payload.append(unit)
                if unit.isKeyframe { sawKeyframe = true }
            }
        }

        // The single most useful line when a stream will not start: it shows whether the
        // random access point is arriving at all, and whether the NAL types are being read
        // with the right codec.
        if Log.verbose {
            Log.debug("access unit ts=\(timestamp) NAL types \(units.map(\.typeValue)) keyframe=\(units.contains { $0.isKeyframe })")
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
        let types = requiredParameterSetTypes
        guard types.allSatisfy({ parameterSets[$0] != nil }) else { return }

        // Copy the parameter sets into flat buffers so the C arrays of pointers stay valid
        // for the duration of the call. They are tens of bytes each.
        var buffers: [UnsafeMutablePointer<UInt8>] = []
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        for type in types {
            let data = parameterSets[type]!
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: buffer, count: data.count)
            buffers.append(buffer)
            pointers.append(UnsafePointer(buffer))
            sizes.append(data.count)
        }
        defer { buffers.forEach { $0.deallocate() } }

        var newFormat: CMVideoFormatDescription?
        let created: OSStatus = pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                switch codec {
                case .h264:
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointerBuffer.count,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,           // matches AnnexB.lengthPrefixed
                        formatDescriptionOut: &newFormat
                    )
                case .h265:
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointerBuffer.count,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &newFormat
                    )
                }
            }
        }

        guard created == noErr, let newFormat else {
            Log.error("could not build a \(codec.rawValue) format description from the parameter sets (status \(created))")
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
        Log.info("\(codec.rawValue) decoder ready: \(dimensions.width)x\(dimensions.height)")
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
