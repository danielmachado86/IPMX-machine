import CX265
import CoreVideo
import Foundation
import IPMXCore

/// Thin wrapper over libx265.
///
/// Same reasoning as the H.264 side: TR-10-15 Part 2 §10 requires HRD Type II with Buffering
/// Period and Picture Timing SEI, and VideoToolbox exposes no way to configure HRD or inject
/// SEI. x265 emits all of it from `bEmitHRDSEI`.
final class X265Encoder: VideoEncoder {
    let codec = VideoCodec.h265

    private var handle: OpaquePointer?
    private var parameters: UnsafeMutablePointer<x265_param>
    private var picture = x265_picture()
    private let deinterleaver: ChromaDeinterleaver
    private let configuration: EncoderConfiguration

    private var vps: NALUnit?
    private var sps: NALUnit?
    private var pps: NALUnit?

    var formatParameters: VideoFormatParameters? {
        guard let vps, let sps, let pps,
              let hevc = ParameterSets.hevcFormatParameters(vps: vps, sps: sps, pps: pps) else {
            return nil
        }
        return .h265(hevc)
    }

    init(configuration: EncoderConfiguration) throws {
        self.configuration = configuration
        self.deinterleaver = ChromaDeinterleaver(width: configuration.width, height: configuration.height)

        // x265 documents x265_param_alloc as the supported way to get a correctly sized
        // struct; the layout is not part of its ABI guarantee.
        guard let allocated = x265_param_alloc() else {
            throw EncoderError.parameterSetup("x265_param_alloc returned null")
        }
        parameters = allocated

        guard x265_param_default_preset(parameters, configuration.preset, "zerolatency") == 0 else {
            x265_param_free(parameters)
            throw EncoderError.parameterSetup("unknown preset \(configuration.preset)")
        }

        parameters.pointee.sourceWidth = Int32(configuration.width)
        parameters.pointee.sourceHeight = Int32(configuration.height)
        parameters.pointee.fpsNum = UInt32(configuration.frameRate)
        parameters.pointee.fpsDenom = 1

        // Main 8-bit 4:2:0, the minimum TR-10-15 Part 2 §12 asks a sender to support.
        parameters.pointee.internalCsp = Int32(X265_CSP_I420)
        parameters.pointee.internalBitDepth = 8

        parameters.pointee.bAnnexB = 1                  // start codes; the packetizer strips them
        parameters.pointee.bRepeatHeaders = 1           // VPS/SPS/PPS before every IRAP
        parameters.pointee.bEnableAccessUnitDelimiters = 0
        parameters.pointee.keyframeMax = Int32(configuration.frameRate * configuration.keyframeIntervalSeconds)

        // TR-10-15 Part 2 §10: decode order shall equal output order, and
        // sps_max_num_reorder_pics should be 0. No B frames, closed GOP.
        parameters.pointee.bframes = 0
        parameters.pointee.bOpenGOP = 0

        parameters.pointee.rc.rateControlMode = Int32(X265_RC_ABR.rawValue)
        parameters.pointee.rc.bitrate = Int32(configuration.bitrateKbps)
        parameters.pointee.rc.vbvMaxBitrate = Int32(configuration.bitrateKbps)
        parameters.pointee.rc.vbvBufferSize = Int32(configuration.bitrateKbps)   // 1 s of CPB

        // TR-10-15 Part 2 §8 wants the colour description present. BT.709 narrow range matches
        // the video-range pixel format ScreenCaptureKit gives us.
        parameters.pointee.vui.bEnableVideoSignalTypePresentFlag = 1
        parameters.pointee.vui.bEnableColorDescriptionPresentFlag = 1
        parameters.pointee.vui.bEnableVideoFullRangeFlag = 0
        parameters.pointee.vui.colorPrimaries = 1                // BT.709
        parameters.pointee.vui.transferCharacteristics = 1       // BT.709
        parameters.pointee.vui.matrixCoeffs = 1                  // BT.709

        if configuration.enableHRD {
            parameters.pointee.bEmitHRDSEI = 1
        }

        guard x265_param_apply_profile(parameters, configuration.profile) == 0 else {
            x265_param_free(parameters)
            throw EncoderError.parameterSetup("profile \(configuration.profile) rejected")
        }

        guard let opened = ipmx_x265_encoder_open(parameters) else {
            x265_param_free(parameters)
            throw EncoderError.open("x265_encoder_open failed; check that libx265 is built for 8-bit")
        }
        // x265_encoder is opaque, so Swift already imports `x265_encoder *` as OpaquePointer.
        handle = opened

        x265_picture_init(parameters, &picture)
        picture.colorSpace = Int32(X265_CSP_I420)
        picture.bitDepth = 8

        Log.info("x265 build \(ipmx_x265_build_number()), \(configuration.width)x\(configuration.height)@\(configuration.frameRate), \(configuration.bitrateKbps) kbps, profile \(configuration.profile), HRD \(configuration.enableHRD ? "on" : "off")")
    }

    deinit {
        if let handle {
            x265_encoder_close(handle)
        }
        x265_param_free(parameters)
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTimestamp: Int64) throws -> [NALUnit] {
        guard let handle else { return [] }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let planes = try deinterleaver.deinterleave(pixelBuffer: pixelBuffer)

        // Luma goes in by reference; only chroma was copied.
        ipmx_x265_pic_set_plane(&picture, 0, planes.luma, Int32(planes.lumaStride))
        ipmx_x265_pic_set_plane(&picture, 1, planes.cb, Int32(planes.chromaStride))
        ipmx_x265_pic_set_plane(&picture, 2, planes.cr, Int32(planes.chromaStride))
        picture.pts = presentationTimestamp

        var nalPointer: UnsafeMutablePointer<x265_nal>?
        var nalCount: UInt32 = 0
        var outputPicture = x265_picture()

        let produced = x265_encoder_encode(handle,
                                           &nalPointer, &nalCount, &picture, &outputPicture)
        guard produced >= 0 else { throw EncoderError.encode("x265_encoder_encode returned \(produced)") }
        guard let nals = nalPointer, nalCount > 0 else { return [] }

        var units: [NALUnit] = []
        units.reserveCapacity(Int(nalCount))
        for index in 0..<Int(nalCount) {
            let nal = nals[index]
            guard let payload = nal.payload, nal.sizeBytes > 0 else { continue }
            // payload includes the Annex B start code; split() strips it.
            let framed = Data(bytes: payload, count: Int(nal.sizeBytes))
            units.append(contentsOf: AnnexB.split(framed, codec: .h265))
        }

        if Log.verbose {
            Log.debug("x265 access unit: NAL types \(units.map(\.typeValue))")
        }

        captureParameterSets(from: units)
        return units
    }

    private func captureParameterSets(from units: [NALUnit]) {
        for unit in units {
            switch unit.typeValue {
            case H265NALType.vps.rawValue: if vps == nil { vps = unit }
            case H265NALType.sps.rawValue: if sps == nil { sps = unit }
            case H265NALType.pps.rawValue: if pps == nil { pps = unit }
            default: break
            }
        }
    }
}
