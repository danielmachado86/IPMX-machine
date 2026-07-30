import CoreVideo
import Dispatch
import Foundation
import IPMXCore

/// Drives encoding from a fixed-rate timer rather than from capture callbacks.
///
/// TR-10-15 §15 is explicit that "the nominal period (T) between video frames/fields is a
/// constant value in seconds" and that the encoder is expected to transmit Sender Reports at
/// that same nominal interval — and that a frame the encoder skips still gets its report. A
/// pipeline driven straight off ScreenCaptureKit cannot honour that: SCK only delivers a
/// `.complete` frame when something on screen actually changed, so an idle desktop stops the
/// stream dead.
///
/// So capture *submits* into a slot and the timer *pulls* from it. A static screen re-encodes
/// the last buffer instead of stalling, which is exactly the behaviour a constant-cadence
/// sender needs.
///
/// The timer is a DispatchSourceTimer with zero leeway, which is good to well under a
/// millisecond. Phase 3 replaces it with the real-time thread that also does the CINST/CMAX
/// pacing.
final class FrameCadence {
    typealias Handler = (CVPixelBuffer, UInt64) -> Void

    private let frameRate: Int
    private let handler: Handler
    private let queue = DispatchQueue(label: "tv.vsf.ipmx.cadence", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var generation: UInt64 = 0
    private var lastEncodedGeneration: UInt64 = 0
    private var frameIndex: UInt64 = 0

    /// Ticks that re-encoded the previous buffer because capture had nothing new.
    private(set) var repeatedFrames: UInt64 = 0

    init(frameRate: Int, handler: @escaping Handler) {
        self.frameRate = frameRate
        self.handler = handler
    }

    /// Called from the capture queue. Cheap on purpose: it only retains the buffer.
    func submit(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        latest = pixelBuffer
        generation &+= 1
        lock.unlock()
    }

    func start() {
        let interval = 1.0 / Double(frameRate)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .nanoseconds(0))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        lock.lock()
        // Nothing captured yet: the stream has not started, so there is no cadence to keep.
        guard let buffer = latest else { lock.unlock(); return }
        if generation == lastEncodedGeneration { repeatedFrames &+= 1 }
        lastEncodedGeneration = generation
        let index = frameIndex
        frameIndex &+= 1
        lock.unlock()

        handler(buffer, index)
    }
}
