import CX264
import CoreVideo
import Foundation
import IPMXCore

/// Thin wrapper over libx264.
///
/// x264 rather than VideoToolbox on purpose: TR-10-15 Part 3 §10 requires HRD Type II with
/// Buffering Period and Picture Timing SEI, and VideoToolbox exposes no way to configure HRD
/// or to inject SEI. x264 emits all of it from `--nal-hrd`. Phase 0 does not switch HRD on
/// yet (see `enableHRD`), but starting here means Phase 1 is a flag flip rather than a
/// bitstream-rewriting project.
final class X264Encoder: VideoEncoder {
    let codec = VideoCodec.h264

    private var handle: OpaquePointer?
    private var picture = x264_picture_t()
    private let configuration: EncoderConfiguration

    private var sps: NALUnit?
    private var pps: NALUnit?

    var formatParameters: VideoFormatParameters? {
        guard let sps, let pps else { return nil }
        return .h264(H264FormatParameters(
            profileLevelID: ParameterSets.profileLevelID(sps: sps),
            spropParameterSets: ParameterSets.sprop(sps: sps, pps: pps)
        ))
    }

    init(configuration: EncoderConfiguration) throws {
        self.configuration = configuration

        var params = x264_param_t()
        guard x264_param_default_preset(&params, configuration.preset, "zerolatency") == 0 else {
            throw EncoderError.parameterSetup("unknown preset \(configuration.preset)")
        }

        // ScreenCaptureKit hands us biplanar 4:2:0, which is exactly x264's NV12 input CSP —
        // no colour conversion needed anywhere in the H.264 path. x265 is not so accommodating,
        // see ChromaDeinterleaver.
        params.i_csp = Int32(X264_CSP_NV12)
        params.i_width = Int32(configuration.width)
        params.i_height = Int32(configuration.height)
        params.i_fps_num = UInt32(configuration.frameRate)
        params.i_fps_den = 1
        params.i_timebase_num = 1
        params.i_timebase_den = UInt32(MediaClock.rate)

        params.b_annexb = 1                 // start codes; the packetizer strips them
        params.b_repeat_headers = 1         // SPS/PPS before every IDR, so late joiners recover
        params.b_aud = 0
        params.i_keyint_max = Int32(configuration.frameRate * configuration.keyframeIntervalSeconds)

        // TR-10-15 Part 3 §10: decode order shall equal output order, max_num_reorder_frames = 0.
        params.i_bframe = 0
        params.b_open_gop = 0
        params.i_sync_lookahead = 0

        // VUI. TR-10-15 Part 3 §8 wants the colour description present; BT.709 narrow range is
        // what ScreenCaptureKit gives us with the video-range pixel format.
        params.vui.b_fullrange = 0
        params.vui.i_colorprim = 1          // BT.709
        params.vui.i_transfer = 1           // BT.709
        params.vui.i_colmatrix = 1          // BT.709

        params.rc.i_rc_method = Int32(X264_RC_ABR)
        params.rc.i_bitrate = Int32(configuration.bitrateKbps)
        params.rc.i_vbv_max_bitrate = Int32(configuration.bitrateKbps)
        params.rc.i_vbv_buffer_size = Int32(configuration.bitrateKbps)   // 1 s of CPB

        if configuration.enableHRD {
            params.i_nal_hrd = Int32(X264_NAL_HRD_VBR)
        }

        // Guarantee the tools each profile is defined by, whatever the preset turned off.
        // Without this a fast preset quietly downgrades the stream below what TR-10-15 Part 3
        // §12 allows, and nothing in the API complains.
        switch configuration.profile {
        case "high":
            params.b_cabac = 1
            params.analyse.b_transform_8x8 = 1
        case "main":
            params.b_cabac = 1
        default:
            break
        }

        guard x264_param_apply_profile(&params, configuration.profile) == 0 else {
            throw EncoderError.parameterSetup("profile \(configuration.profile) rejected")
        }

        // x264_t is opaque, so Swift already imports `x264_t *` as OpaquePointer.
        guard let opened = ipmx_x264_encoder_open(&params) else {
            throw EncoderError.open("x264_encoder_open failed")
        }
        handle = opened

        x264_picture_init(&picture)
        picture.img.i_csp = Int32(X264_CSP_NV12)
        picture.img.i_plane = 2

        Log.info("x264 build \(ipmx_x264_build_number()), \(configuration.width)x\(configuration.height)@\(configuration.frameRate), \(configuration.bitrateKbps) kbps, profile \(configuration.profile), HRD \(configuration.enableHRD ? "on" : "off")")
    }

    deinit {
        if let handle {
            x264_encoder_close(handle)
        }
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTimestamp: Int64) throws -> [NALUnit] {
        guard let handle else { return [] }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            throw EncoderError.unexpectedPixelFormat
        }

        ipmx_x264_pic_set_plane(&picture, 0,
                                luma.assumingMemoryBound(to: UInt8.self),
                                Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)))
        ipmx_x264_pic_set_plane(&picture, 1,
                                chroma.assumingMemoryBound(to: UInt8.self),
                                Int32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)))
        picture.i_pts = presentationTimestamp

        var nalPointer: UnsafeMutablePointer<x264_nal_t>?
        var nalCount: Int32 = 0
        var outputPicture = x264_picture_t()

        let size = x264_encoder_encode(handle, &nalPointer, &nalCount, &picture, &outputPicture)
        guard size >= 0 else { throw EncoderError.encode("x264_encoder_encode returned \(size)") }
        guard size > 0, let nals = nalPointer, nalCount > 0 else { return [] }

        var units: [NALUnit] = []
        units.reserveCapacity(Int(nalCount))
        for index in 0..<Int(nalCount) {
            let nal = nals[index]
            guard let payload = nal.p_payload, nal.i_payload > 0 else { continue }
            // p_payload includes the Annex B start code; split() strips it.
            let framed = Data(bytes: payload, count: Int(nal.i_payload))
            units.append(contentsOf: AnnexB.split(framed, codec: .h264))
        }

        captureParameterSets(from: units)
        return units
    }

    private func captureParameterSets(from units: [NALUnit]) {
        for unit in units {
            if unit.typeValue == H264NALType.sps.rawValue, sps == nil { sps = unit }
            if unit.typeValue == H264NALType.pps.rawValue, pps == nil { pps = unit }
        }
    }
}
