import CoreMedia
import CoreVideo
import Foundation
import IPMXCore
import ScreenCaptureKit

/// ScreenCaptureKit capture of a single display, delivered as NV12 pixel buffers.
///
/// Requires the Screen Recording privacy permission. When the binary is launched from a
/// terminal, macOS attributes the permission to the terminal application, so the first run
/// prompts once and then needs that app restarted.
final class ScreenSource: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Configuration {
        var width: Int
        var height: Int
        var frameRate: Int
        var displayIndex: Int = 0
        var showsCursor: Bool = true
    }

    /// Called on `captureQueue` for every complete frame.
    typealias FrameHandler = (CVPixelBuffer, CMTime) -> Void

    private let configuration: Configuration
    private let handler: FrameHandler
    private let captureQueue = DispatchQueue(label: "tv.vsf.ipmx.capture", qos: .userInteractive)
    private var stream: SCStream?

    init(configuration: Configuration, handler: @escaping FrameHandler) {
        self.configuration = configuration
        self.handler = handler
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else { throw SourceError.noDisplays }
        let index = min(configuration.displayIndex, content.displays.count - 1)
        let display = content.displays[index]

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = configuration.width
        streamConfiguration.height = configuration.height
        // Biplanar 4:2:0 video range: feeds x264's NV12 input CSP with zero conversion,
        // and the limited range matches the RANGE=NARROW we advertise in the SDP.
        streamConfiguration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        streamConfiguration.colorSpaceName = CGColorSpace.itur_709
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate))
        streamConfiguration.queueDepth = 6
        streamConfiguration.showsCursor = configuration.showsCursor

        let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        self.stream = stream

        Log.info("capturing display \(index) (\(display.width)x\(display.height)) -> \(configuration.width)x\(configuration.height)@\(configuration.frameRate)")
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }

        // ScreenCaptureKit also emits .idle and .blank frames when nothing changed on screen.
        // Encoding those would be wasted work; a real IPMX sender must still emit a frame on
        // schedule, which is Phase 2 territory once RTCP Sender Reports need a fixed cadence.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handler(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("capture stopped: \(error.localizedDescription)")
        exit(1)
    }

    enum SourceError: Error, CustomStringConvertible {
        case noDisplays
        var description: String { "no displays available for capture" }
    }
}
