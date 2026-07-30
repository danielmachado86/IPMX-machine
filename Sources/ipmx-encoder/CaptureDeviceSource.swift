import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import IPMXCore

/// HDMI/SDI ingest through an AVFoundation capture device.
///
/// Aimed at Magewell, which is UVC class compliant and therefore needs no vendor SDK at all:
/// the card shows up as an `AVCaptureDevice` of type `.external` and the whole integration is
/// standard AVFoundation. Blackmagic DeckLink and AJA need their own C++ SDKs instead, and
/// would be a sibling of this file rather than a change to it.
///
/// Two things this deliberately does not do yet:
///  - It does not follow a change of input resolution mid-stream. The encoder is configured
///    once, so a resolution change on the HDMI input needs the whole pipeline rebuilt.
///  - It cannot report the real raster. UVC delivers frames, not blanking intervals, so
///    htotal, vtotal and the pixel clock still come from TR-10-9 §10 rather than from a
///    measurement of the incoming signal as TR-10-1 §10.2 would prefer. Getting those needs a
///    device SDK that exposes signal timing.
final class CaptureDeviceSource: NSObject, VideoSource, AVCaptureVideoDataOutputSampleBufferDelegate {

    struct Configuration {
        var width: Int
        var height: Int
        var frameRate: Int
    }

    /// Called on the capture queue for each frame, with the presentation time in the same
    /// monotonic epoch as `MonotonicClock.now()`.
    typealias FrameHandler = (CVPixelBuffer, Double) -> Void

    private let device: AVCaptureDevice
    private let configuration: Configuration
    private let handler: FrameHandler
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "tv.vsf.ipmx.capture.device", qos: .userInteractive)
    private var converter: PixelFormatConverter?

    private(set) var droppedFrames: UInt64 = 0

    init(device: AVCaptureDevice, configuration: Configuration, handler: @escaping FrameHandler) {
        self.device = device
        self.configuration = configuration
        self.handler = handler
        super.init()
    }

    // MARK: Device discovery

    /// External devices first, since that is what a capture card is; the built-in camera is
    /// included so the ingest path can be exercised without a card plugged in.
    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// Resolves an index or a case-insensitive substring of the device name.
    static func device(matching selector: String?) -> AVCaptureDevice? {
        let devices = availableDevices()
        guard let selector, !selector.isEmpty else {
            // Prefer a real capture card over the built-in camera when nothing was asked for.
            return devices.first { $0.deviceType == .external } ?? devices.first
        }
        if let index = Int(selector), devices.indices.contains(index) {
            return devices[index]
        }
        let needle = selector.lowercased()
        return devices.first { $0.localizedName.lowercased().contains(needle) }
            ?? devices.first { $0.uniqueID == selector }
    }

    static func describeDevices() -> String {
        let devices = availableDevices()
        guard !devices.isEmpty else { return "no video capture devices found" }

        var lines: [String] = []
        for (index, device) in devices.enumerated() {
            let kind = device.deviceType == .external ? "external" : "built-in"
            lines.append("  [\(index)] \(device.localizedName)  (\(kind))")
            lines.append("        id: \(device.uniqueID)")
            for format in device.formats {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let subType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                let rates = format.videoSupportedFrameRateRanges
                    .map { range in
                        range.minFrameRate == range.maxFrameRate
                            ? String(format: "%g", range.maxFrameRate)
                            : String(format: "%g-%g", range.minFrameRate, range.maxFrameRate)
                    }
                    .joined(separator: ",")
                lines.append("        \(dimensions.width)x\(dimensions.height) "
                           + "'\(PixelFormatConverter.fourCC(subType))' @ \(rates) fps")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Lifecycle

    func start() async throws {
        guard await Self.requestAccess() else {
            throw SourceError.accessDenied
        }

        guard let format = selectFormat() else {
            throw SourceError.noMatchingFormat(width: configuration.width,
                                               height: configuration.height,
                                               frameRate: configuration.frameRate)
        }

        try device.lockForConfiguration()
        device.activeFormat = format
        // Pin the rate so the device does not drift into a lower one under light. Harmless on a
        // capture card, which just reports what the source is doing.
        let duration = CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate))
        if format.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= Double(configuration.frameRate)
                && Double(configuration.frameRate) <= $0.maxFrameRate
        }) {
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
        device.unlockForConfiguration()

        session.beginConfiguration()
        // No sessionPreset on purpose: `.inputPriority` is iOS only, and on macOS setting a
        // preset would override the activeFormat chosen above. Leaving it alone honours it.

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw SourceError.cannotAddInput }
        session.addInput(input)

        // Ask the output for NV12 directly when it can do it — that keeps the H.264 path free
        // of any colour conversion, the way ScreenCaptureKit already is. Otherwise take what
        // the device gives and convert with VideoToolbox.
        let preferred = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let native = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let available = output.availableVideoPixelFormatTypes
        let chosen = available.contains(preferred) ? preferred : (available.first ?? native)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: chosen]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else { throw SourceError.cannotAddOutput }
        session.addOutput(output)
        session.commitConfiguration()

        if chosen != preferred {
            converter = try PixelFormatConverter(width: configuration.width,
                                                 height: configuration.height)
            Log.info("converting \(PixelFormatConverter.fourCC(chosen)) -> "
                   + "\(PixelFormatConverter.fourCC(preferred)) with VTPixelTransferSession")
        } else {
            Log.debug("device delivers NV12 directly, no colour conversion needed")
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        Log.info("ingesting from \(device.localizedName): \(dimensions.width)x\(dimensions.height) "
               + "'\(PixelFormatConverter.fourCC(native))' @ \(configuration.frameRate) fps")

        session.startRunning()
    }

    func stop() async {
        session.stopRunning()
    }

    private static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Strict on purpose. Falling back to a format that cannot reach the requested rate would
    /// leave the encoder, the SDP's `exactframerate` and the Media Info Block all claiming a
    /// rate the device never produces — a silent lie in exactly the fields a receiver uses to
    /// derive its timing.
    private func selectFormat() -> AVCaptureDevice.Format? {
        device.formats.first { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(dimensions.width) == configuration.width,
                  Int(dimensions.height) == configuration.height else { return false }
            return format.videoSupportedFrameRateRanges.contains { range in
                range.minFrameRate <= Double(configuration.frameRate)
                    && Double(configuration.frameRate) <= range.maxFrameRate
            }
        }
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pixelBuffer: CVPixelBuffer
        if let converter {
            do {
                pixelBuffer = try converter.convert(imageBuffer)
            } catch {
                Log.error("\(error)")
                return
            }
        } else {
            pixelBuffer = imageBuffer
        }

        // AVFoundation stamps presentation times on the host time clock, which shares its epoch
        // with CLOCK_UPTIME_RAW, so this is directly comparable to MonotonicClock.now().
        let presentationTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        handler(pixelBuffer, presentationTime)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        droppedFrames &+= 1
    }

    enum SourceError: Error, CustomStringConvertible {
        case accessDenied
        case noMatchingFormat(width: Int, height: Int, frameRate: Int)
        case cannotAddInput
        case cannotAddOutput

        var description: String {
            switch self {
            case .accessDenied:
                return "camera access denied. macOS attributes it to the terminal application, "
                     + "so grant it in System Settings > Privacy & Security > Camera and restart the terminal"
            case .noMatchingFormat(let width, let height, let frameRate):
                return "the device has no \(width)x\(height) format that reaches \(frameRate) fps. "
                     + "Run with --list-devices to see what it offers"
            case .cannotAddInput:  return "the capture session refused the device input"
            case .cannotAddOutput: return "the capture session refused the video output"
            }
        }
    }
}
