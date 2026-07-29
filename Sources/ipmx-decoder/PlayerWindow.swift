import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import IPMXCore

/// A plain NSWindow backed by an AVSampleBufferDisplayLayer.
///
/// The layer is fed already-decoded CVPixelBuffers, so it acts purely as a compositor.
/// Feeding it the compressed samples directly would also work and would be less code, but
/// keeping the explicit VTDecompressionSession leaves the hook we need later for the
/// receiver buffer model and `ext_link_offset_delay`.
final class PlayerWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let displayLayer = AVSampleBufferDisplayLayer()

    init(width: Int, height: Int, title: String) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = title
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false

        let hostView = NSView(frame: window.contentView?.bounds ?? .zero)
        hostView.wantsLayer = true
        hostView.layer = CALayer()
        hostView.layer?.backgroundColor = NSColor.black.cgColor
        hostView.autoresizingMask = [.width, .height]

        displayLayer.frame = hostView.bounds
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        hostView.layer?.addSublayer(displayLayer)

        window.contentView = hostView
        window.makeKeyAndOrderFront(nil)
    }

    /// Must be called on the main thread.
    func present(imageBuffer: CVImageBuffer, presentationTime: CMTime) {
        guard let sampleBuffer = Self.wrap(imageBuffer: imageBuffer, presentationTime: presentationTime) else {
            return
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        renderer.enqueue(sampleBuffer)
    }

    func updateTitle(_ text: String) {
        window.title = text
    }

    private static func wrap(imageBuffer: CVImageBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime.isValid ? presentationTime : .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        // Phase 0 has no receiver buffer and no playout schedule: show every frame on arrival.
        // Phase 4 replaces this with a real playout time derived from ext_link_offset_delay.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.terminate(nil)
    }
}
