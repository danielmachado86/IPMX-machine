import CoreVideo
import Dispatch
import Foundation
import IPMXCore

/// Decides when a frame exists, which is not the same question for the two source kinds.
///
/// TR-10-15 §15 requires a constant nominal period between frames and forbids skipping the
/// Sender Report of a frame the encoder skipped. Both modes below exist to honour that, from
/// opposite directions:
///
/// - `timerDriven` — for ScreenCaptureKit, which only delivers a `.complete` frame when
///   something on screen changed. Capture *submits* into a slot and the timer *pulls*, so an
///   idle desktop re-encodes the last buffer instead of stopping the stream dead.
///
/// - `sourceDriven` — for a capture card, whose own clock is the authority. Here a local timer
///   would be actively harmful: two free-running clocks drift, so a pulled pipeline would
///   repeat or drop a frame periodically for no reason. The device drives, and the timer is
///   demoted to a watchdog that only fires when the signal stops.
final class FrameCadence {

    enum Mode {
        case timerDriven
        case sourceDriven
    }

    struct Tick {
        let pixelBuffer: CVPixelBuffer
        /// Monotonic seconds, the same epoch as `MonotonicClock.now()`.
        let presentationTime: Double
        let frameIndex: UInt64
        /// True when this is the previous buffer sent again to keep the cadence.
        let isRepeat: Bool
    }

    typealias Handler = (Tick) -> Void

    let mode: Mode
    private let frameRate: Int
    private let handler: Handler
    private let queue = DispatchQueue(label: "tv.vsf.ipmx.cadence", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var latestPresentationTime: Double = 0
    private var generation: UInt64 = 0
    private var lastDeliveredGeneration: UInt64 = 0
    private var lastDeliveryTime: Double = 0
    private var frameIndex: UInt64 = 0

    /// Ticks that resent the previous buffer because nothing new had arrived.
    private(set) var repeatedFrames: UInt64 = 0

    init(mode: Mode, frameRate: Int, handler: @escaping Handler) {
        self.mode = mode
        self.frameRate = frameRate
        self.handler = handler
    }

    /// Called from whichever queue the source runs on. Cheap: it retains the buffer and, in
    /// source-driven mode, hands it straight to the cadence queue.
    func submit(_ pixelBuffer: CVPixelBuffer, presentationTime: Double) {
        lock.lock()
        latest = pixelBuffer
        latestPresentationTime = presentationTime
        generation &+= 1
        lock.unlock()

        guard mode == .sourceDriven else { return }
        queue.async { [weak self] in self?.deliver(force: true) }
    }

    func start() {
        let period = 1.0 / Double(frameRate)
        let source = DispatchSource.makeTimerSource(queue: queue)

        switch mode {
        case .timerDriven:
            source.schedule(deadline: .now() + period, repeating: period, leeway: .nanoseconds(0))
            source.setEventHandler { [weak self] in self?.deliver(force: false) }
        case .sourceDriven:
            // Only needs to notice that the signal stopped, so it runs at the frame rate but
            // acts on a 1.5-period staleness threshold to avoid racing a slightly late frame.
            source.schedule(deadline: .now() + period, repeating: period, leeway: .milliseconds(1))
            source.setEventHandler { [weak self] in self?.deliverIfStale(threshold: period * 1.5) }
        }

        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func deliver(force: Bool) {
        lock.lock()
        guard let buffer = latest else { lock.unlock(); return }

        let isRepeat = generation == lastDeliveredGeneration
        // In source-driven mode a timer wake-up that found nothing new is handled by
        // deliverIfStale; a forced delivery always carries a genuinely new frame.
        if isRepeat && !force { repeatedFrames &+= 1 }
        lastDeliveredGeneration = generation
        lastDeliveryTime = MonotonicClock.now()

        let tick = Tick(pixelBuffer: buffer,
                        presentationTime: mode == .timerDriven
                            ? MonotonicClock.now() : latestPresentationTime,
                        frameIndex: frameIndex,
                        isRepeat: isRepeat)
        frameIndex &+= 1
        lock.unlock()

        handler(tick)
    }

    /// Watchdog for the source-driven mode: the input went away, so repeat the last picture
    /// rather than let the Sender Report cadence stop.
    private func deliverIfStale(threshold: Double) {
        lock.lock()
        let stale = latest != nil && MonotonicClock.now() - lastDeliveryTime > threshold
        lock.unlock()
        guard stale else { return }
        deliver(force: false)
    }
}
