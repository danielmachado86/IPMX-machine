import Darwin
import Dispatch
import Foundation

/// TR-10-7 §10 parameters for the ST 2110-21 Network Compatibility Model.
///
/// `maxPacketRate` is MaxRate from TR-10-7, in RTP packets per second. CMAX uses integer
/// truncation exactly as the recommendation specifies.
public struct TrafficShapeParameters: Sendable, Equatable {
    public static let cmaxDivisor = 21_600.0

    /// Fraction of CMAX the bucket is actually sized to.
    ///
    /// Sizing the bucket at exactly CMAX is compliant but leaves no margin, and it shows: a
    /// loopback measurement of this sender put 37% of packets at exactly CINST = 16 against a
    /// CMAX of 16, with an observed peak of 16.11 once measurement bias was included. Anything
    /// downstream that adds burstiness — CDC-NCM aggregating frames into USB transfers, switch
    /// queuing, an analyser that rounds differently — then pushes a conformant sender over the
    /// line. TR-10-1 §8.1 calls CMAX "the maximum allowed value", so staying under it is
    /// explicitly correct.
    public static let defaultHeadroomFraction = 0.875

    public let maxPacketRate: Double

    /// The normative ceiling, TR-10-7 §10: `CMAX = MAX(16, INT(MaxRate / 21600))`.
    public let cmax: Int

    /// What the token bucket is actually sized to. At or below `cmax`.
    public let burstCapacity: Int

    public init(maxPacketRate: Double,
                headroomFraction: Double = defaultHeadroomFraction) {
        precondition(maxPacketRate.isFinite && maxPacketRate > 0,
                     "MaxRate must be a positive finite packet rate")
        precondition(headroomFraction > 0 && headroomFraction <= 1,
                     "headroom is a fraction of CMAX, and never above it")
        self.maxPacketRate = maxPacketRate
        let ceiling = max(16, Int(maxPacketRate / Self.cmaxDivisor))
        self.cmax = ceiling
        self.burstCapacity = max(1, Int((Double(ceiling) * headroomFraction).rounded(.down)))
    }

    /// Converts a maximum encoded bitrate to a conservative packet-rate target.
    ///
    /// Compressed access units end in a partial packet and carry small parameter-set/SEI NALs,
    /// so assuming every packet is completely full underestimates MaxRate. A 75% minimum
    /// average fill is deliberately conservative and can be replaced with a measured value
    /// through the encoder's `--max-packet-rate` option.
    public static func estimatedMaxPacketRate(maxBitrateKbps: Int,
                                              maxRTPPayloadBytes: Int,
                                              frameRate: Int,
                                              auxiliaryPacketsPerFrame: Int = 4,
                                              minimumAverageFill: Double = 0.75) -> Double {
        precondition(maxBitrateKbps > 0)
        precondition(maxRTPPayloadBytes > 0)
        precondition(frameRate > 0)
        precondition(auxiliaryPacketsPerFrame >= 0)
        precondition(minimumAverageFill > 0 && minimumAverageFill <= 1)

        let usablePayloadBits = Double(maxRTPPayloadBytes) * 8.0 * minimumAverageFill
        let packetsForCodedBytes = ceil(Double(maxBitrateKbps) * 1_000.0 / usablePayloadBits)
        let perFrameAllowance = Double(frameRate * auxiliaryPacketsPerFrame)
        return packetsForCodedBytes + perFrameAllowance
    }

    /// IPv4 + UDP + the fixed RTP header, which is what packetizing adds to every packet.
    public static let ipUDPRTPHeaderBytes = 20 + 8 + 12

    /// The value TR-10-7 §11 wants in `b=AS`.
    ///
    /// > The `<brvalue>` shall be the maximum target bit rate of the encoded media stream...
    /// > The bit rate shall include the whole of each IP packet, i.e. IP headers and payload.
    ///
    /// So the coded bitrate alone understates it: at MaxRate packets per second the IP, UDP and
    /// RTP headers are themselves a real part of what the network has to carry. Deriving the
    /// advertised rate from the same MaxRate the shaper paces to keeps the SDP and the traffic
    /// shape describing one stream rather than two.
    ///
    /// Not counted: the 2 bytes of FU-A headers (3 for H.265) that fragmentation adds inside
    /// the RTP payload, which the coded bitrate does not include either. Measured on a real
    /// 1080p60 stream that is 1.5 kbit/s against a b=AS of 8382 — 0.018%, so it is left out
    /// rather than estimated from a fragmentation ratio the sender does not know in advance.
    /// Ethernet framing is excluded by TR-10-7 §11 itself: "shall not include layers below IP".
    public func advertisedBitrateKbps(codedBitrateKbps: Int,
                                      headerBytesPerPacket: Int = ipUDPRTPHeaderBytes) -> Int {
        precondition(codedBitrateKbps > 0)
        precondition(headerBytesPerPacket >= 0)
        let headerBitsPerSecond = maxPacketRate * Double(headerBytesPerPacket) * 8.0
        return codedBitrateKbps + Int(ceil(headerBitsPerSecond / 1_000.0))
    }
}

/// Configuration for the asynchronous macOS traffic-shaping worker.
public struct TrafficShaperConfiguration: Sendable, Equatable {
    public var parameters: TrafficShapeParameters
    public var queueCapacity: Int
    public var spinThresholdNanoseconds: UInt64

    public init(parameters: TrafficShapeParameters,
                queueCapacity: Int = 8_192,
                spinThresholdNanoseconds: UInt64 = 50_000) {
        precondition(queueCapacity > 0)
        self.parameters = parameters
        self.queueCapacity = queueCapacity
        self.spinThresholdNanoseconds = spinThresholdNanoseconds
    }
}

/// Pure token-bucket scheduler used by the real-time worker and by deterministic tests.
///
/// The bucket starts full and refills at MaxRate tokens per second. Its size is
/// `burstCapacity`, which sits deliberately below CMAX so that burstiness added downstream
/// does not push an otherwise conformant sender over the normative limit.
public struct TrafficShapeTokenBucket: Sendable {
    public let parameters: TrafficShapeParameters
    private var tokens: Double
    private var lastUpdateNanoseconds: UInt64

    public init(parameters: TrafficShapeParameters, originNanoseconds: UInt64) {
        self.parameters = parameters
        self.tokens = Double(parameters.burstCapacity)
        self.lastUpdateNanoseconds = originNanoseconds
    }

    /// Reserves one packet and returns its earliest permitted absolute send time.
    public mutating func reserve(nowNanoseconds: UInt64) -> UInt64 {
        if nowNanoseconds > lastUpdateNanoseconds {
            let elapsed = Double(nowNanoseconds - lastUpdateNanoseconds) / 1_000_000_000.0
            tokens = min(Double(parameters.burstCapacity),
                         tokens + elapsed * parameters.maxPacketRate)
            lastUpdateNanoseconds = nowNanoseconds
        }

        if tokens >= 1.0 {
            tokens -= 1.0
            return nowNanoseconds
        }

        let missing = 1.0 - tokens
        let delay = UInt64(ceil(missing / parameters.maxPacketRate * 1_000_000_000.0))
        let deadline = lastUpdateNanoseconds &+ max(delay, 1)
        tokens = 0
        lastUpdateNanoseconds = deadline
        return deadline
    }
}

public enum TrafficShaperState: Sendable, Equatable, CustomStringConvertible {
    case starting
    case realTime
    case bestEffort(kernReturn: Int32)
    case stopped

    public var description: String {
        switch self {
        case .starting: return "starting"
        case .realTime: return "real-time"
        case .bestEffort(let code): return "best-effort (thread_policy_set=\(code))"
        case .stopped: return "stopped"
        }
    }
}

public struct TrafficShaperSnapshot: Sendable {
    public let state: TrafficShaperState
    public let queuedPackets: Int
    public let queueHighWatermark: Int
    public let packetsSent: UInt64
    public let bytesSent: UInt64
    public let payloadBytesSent: UInt64
    public let sendErrors: UInt64

    /// How far past its reserved instant a packet actually went out. This measures whether the
    /// real-time thread is meeting its own deadlines, and is bounded by the busy-wait, so it
    /// stays in the nanoseconds. It says nothing about whether the shaper is keeping up with
    /// the offered load — that is what the residency figures below are for.
    public let maximumPacingErrorNanoseconds: UInt64

    /// Time a datagram spent between being admitted and reaching the socket. This is the
    /// number that grows without bound when MaxRate is set below what the encoder produces,
    /// so it is the useful overload signal.
    public let maximumQueueResidencyNanoseconds: UInt64
    public let totalQueueResidencyNanoseconds: UInt64

    /// Longest a single `sendto` took. A socket that starts blocking shows up here before it
    /// shows up anywhere else, and it is invisible to the pacing error by construction.
    public let maximumSendDurationNanoseconds: UInt64

    public let lastSendError: String?

    public var meanQueueResidencyNanoseconds: UInt64 {
        packetsSent == 0 ? 0 : totalQueueResidencyNanoseconds / packetsSent
    }
}

/// Userspace packet pacer for macOS.
///
/// macOS has no `SO_TXTIME` or `qdisc etf`, so a dedicated Mach time-constraint thread owns
/// all shaped `sendto()` calls. The producer only places complete RTP datagrams into a fixed
/// ring buffer. The final short wait is a busy-wait; longer waits yield through
/// `mach_wait_until` first.
public final class TrafficShaper: @unchecked Sendable {
    private typealias SendOperation = @Sendable (Data) throws -> Void
    private struct QueuedDatagram {
        let bytes: Data
        let payloadOctets: Int
        let enqueuedAtNanoseconds: UInt64
    }

    /// One RTP datagram waiting for admission.
    public struct PendingDatagram: Sendable {
        public let bytes: Data
        public let payloadOctets: Int

        public init(bytes: Data, payloadOctets: Int) {
            precondition(payloadOctets >= 0)
            self.bytes = bytes
            self.payloadOctets = payloadOctets
        }
    }

    public let configuration: TrafficShaperConfiguration

    private let condition = NSCondition()
    private var ring: [QueuedDatagram?]
    private var readIndex = 0
    private var writeIndex = 0
    private var queued = 0
    private var accepting = true
    private var drainWhenStopping = true

    private var state: TrafficShaperState = .starting
    private var queueHighWatermark = 0
    private var packetsSent: UInt64 = 0
    private var bytesSent: UInt64 = 0
    private var payloadBytesSent: UInt64 = 0
    private var sendErrors: UInt64 = 0
    private var maximumPacingErrorNanoseconds: UInt64 = 0
    private var maximumQueueResidencyNanoseconds: UInt64 = 0
    private var totalQueueResidencyNanoseconds: UInt64 = 0
    private var maximumSendDurationNanoseconds: UInt64 = 0
    private var lastSendError: String?

    private let sendOperation: SendOperation
    private let started = DispatchSemaphore(value: 0)
    private var workerFinished = false
    private var worker: Thread?

    public convenience init(socket: UDPSender, configuration: TrafficShaperConfiguration) {
        self.init(configuration: configuration) { datagram in
            try socket.send(datagram)
        }
    }

    init(configuration: TrafficShaperConfiguration,
         sendOperation: @escaping @Sendable (Data) throws -> Void) {
        self.configuration = configuration
        self.ring = [QueuedDatagram?](repeating: nil, count: configuration.queueCapacity)
        self.sendOperation = sendOperation

        let thread = Thread { [self] in run() }
        thread.name = "tv.vsf.ipmx.traffic-shaper"
        thread.qualityOfService = .userInteractive
        worker = thread
        thread.start()

        // Initialization returns with a definitive scheduling state for startup logging.
        _ = started.wait(timeout: .now() + 2)
    }

    /// Admits a whole batch in transmission order, or none of it.
    ///
    /// Non-blocking on purpose. An earlier version blocked the producer until room appeared,
    /// which looks like honest backpressure but is not: the producer is the cadence thread,
    /// and it is also what emits RTCP Sender Reports. Blocking it stops the Sender Report
    /// cadence that TR-10-15 §15 requires to be constant, and it does so silently. Losing a
    /// frame under overload is recoverable; losing the report cadence is not.
    ///
    /// All-or-nothing because a half-admitted access unit would put a partial frame on the
    /// wire and burn sequence numbers for packets that never leave.
    @discardableResult
    public func enqueue(_ datagrams: [PendingDatagram]) -> Bool {
        guard !datagrams.isEmpty else { return true }
        condition.lock()
        defer { condition.unlock() }

        guard accepting, ring.count - queued >= datagrams.count else { return false }

        let now = MachMonotonicClock.nowNanoseconds()
        for datagram in datagrams {
            ring[writeIndex] = QueuedDatagram(bytes: datagram.bytes,
                                              payloadOctets: datagram.payloadOctets,
                                              enqueuedAtNanoseconds: now)
            writeIndex = (writeIndex + 1) % ring.count
            queued += 1
        }
        queueHighWatermark = max(queueHighWatermark, queued)
        condition.broadcast()
        return true
    }

    @discardableResult
    public func enqueue(_ datagram: Data, payloadOctets: Int = 0) -> Bool {
        enqueue([PendingDatagram(bytes: datagram, payloadOctets: payloadOctets)])
    }

    /// Free slots right now. Only ever grows while a single producer is between calls, so it
    /// is safe to use as a hint; `enqueue` is still the atomic admission point.
    public var availableCapacity: Int {
        condition.lock()
        defer { condition.unlock() }
        return accepting ? ring.count - queued : 0
    }

    /// Stops accepting new packets. With `drain`, all queued packets are paced before exit.
    ///
    /// Idempotent, and safe to call from more than one thread: completion is observed through
    /// the condition variable rather than a one-shot semaphore, which a second caller would
    /// have waited on until its timeout expired.
    @discardableResult
    public func stop(drain: Bool, timeout: TimeInterval = 5) -> Bool {
        condition.lock()
        defer { condition.unlock() }

        if accepting {
            accepting = false
            drainWhenStopping = drain
            if !drain {
                ring = [QueuedDatagram?](repeating: nil, count: ring.count)
                readIndex = 0
                writeIndex = 0
                queued = 0
            }
            condition.broadcast()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !workerFinished {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    public func snapshot() -> TrafficShaperSnapshot {
        condition.lock()
        defer { condition.unlock() }
        return TrafficShaperSnapshot(
            state: state,
            queuedPackets: queued,
            queueHighWatermark: queueHighWatermark,
            packetsSent: packetsSent,
            bytesSent: bytesSent,
            payloadBytesSent: payloadBytesSent,
            sendErrors: sendErrors,
            maximumPacingErrorNanoseconds: maximumPacingErrorNanoseconds,
            maximumQueueResidencyNanoseconds: maximumQueueResidencyNanoseconds,
            totalQueueResidencyNanoseconds: totalQueueResidencyNanoseconds,
            maximumSendDurationNanoseconds: maximumSendDurationNanoseconds,
            lastSendError: lastSendError
        )
    }

    private func run() {
        autoreleasepool {
            let schedulingResult = installTimeConstraintPolicy()
            condition.lock()
            state = schedulingResult == KERN_SUCCESS
                ? .realTime
                : .bestEffort(kernReturn: schedulingResult)
            condition.unlock()
            started.signal()

            var pacer = TrafficShapeTokenBucket(
                parameters: configuration.parameters,
                originNanoseconds: MachMonotonicClock.nowNanoseconds()
            )

            while let datagram = nextDatagram() {
                let reserved = pacer.reserve(nowNanoseconds: MachMonotonicClock.nowNanoseconds())
                wait(untilNanoseconds: reserved)

                // Taken before the send on purpose: this is scheduler accuracy, "did the thread
                // wake when it said it would". Folding the socket call into it would conflate
                // two unrelated failures.
                let woke = MachMonotonicClock.nowNanoseconds()
                let pacingError = woke > reserved ? woke - reserved : 0

                do {
                    try sendOperation(datagram.bytes)

                    // Residency and send duration are taken after, because a blocking sendto is
                    // real time the packet spent inside us and has to show up somewhere.
                    let completed = MachMonotonicClock.nowNanoseconds()
                    let residency = completed > datagram.enqueuedAtNanoseconds
                        ? completed - datagram.enqueuedAtNanoseconds
                        : 0
                    let sendDuration = completed > woke ? completed - woke : 0

                    condition.lock()
                    packetsSent += 1
                    bytesSent += UInt64(datagram.bytes.count)
                    payloadBytesSent += UInt64(datagram.payloadOctets)
                    maximumPacingErrorNanoseconds = max(maximumPacingErrorNanoseconds, pacingError)
                    maximumQueueResidencyNanoseconds = max(maximumQueueResidencyNanoseconds, residency)
                    totalQueueResidencyNanoseconds &+= residency
                    maximumSendDurationNanoseconds = max(maximumSendDurationNanoseconds, sendDuration)
                    condition.unlock()
                } catch {
                    condition.lock()
                    sendErrors += 1
                    lastSendError = String(describing: error)
                    condition.unlock()
                }
            }

            condition.lock()
            state = .stopped
            workerFinished = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private func nextDatagram() -> QueuedDatagram? {
        condition.lock()
        defer { condition.unlock() }

        while queued == 0 && accepting {
            condition.wait()
        }

        if queued == 0 || (!accepting && !drainWhenStopping) {
            return nil
        }

        let datagram = ring[readIndex]
        ring[readIndex] = nil
        readIndex = (readIndex + 1) % ring.count
        queued -= 1
        condition.broadcast()
        return datagram
    }

    private func wait(untilNanoseconds deadline: UInt64) {
        var now = MachMonotonicClock.nowNanoseconds()
        guard now < deadline else { return }

        let spin = configuration.spinThresholdNanoseconds
        if deadline - now > spin {
            let sleepUntil = deadline - spin
            _ = mach_wait_until(MachMonotonicClock.absoluteTicks(forNanoseconds: sleepUntil))
        }

        repeat {
            now = MachMonotonicClock.nowNanoseconds()
        } while now < deadline
    }

    /// Requests a bounded share of each 1 ms scheduling period. Failure is non-fatal and is
    /// exposed in the snapshot so the sender can state that it is operating best-effort.
    private func installTimeConstraintPolicy() -> kern_return_t {
        let policyCount = MemoryLayout<thread_time_constraint_policy_data_t>.size
            / MemoryLayout<integer_t>.size
        var policy = thread_time_constraint_policy_data_t(
            period: UInt32(MachMonotonicClock.absoluteTicks(forNanoseconds: 1_000_000)),
            computation: UInt32(MachMonotonicClock.absoluteTicks(forNanoseconds: 100_000)),
            constraint: UInt32(MachMonotonicClock.absoluteTicks(forNanoseconds: 500_000)),
            preemptible: 1
        )

        // mach_thread_self() hands back a send right that the caller owns. Without the
        // deallocate the reference leaks for the lifetime of the process.
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }

        return withUnsafeMutablePointer(to: &policy) { pointer in
            pointer.withMemoryRebound(to: integer_t.self,
                                      capacity: policyCount) {
                thread_policy_set(thread,
                                  thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY),
                                  $0,
                                  mach_msg_type_number_t(policyCount))
            }
        }
    }
}

private enum MachMonotonicClock {
    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func nowNanoseconds() -> UInt64 {
        nanoseconds(forAbsoluteTicks: mach_absolute_time())
    }

    static func nanoseconds(forAbsoluteTicks ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    static func absoluteTicks(forNanoseconds nanoseconds: UInt64) -> UInt64 {
        nanoseconds * UInt64(timebase.denom) / UInt64(timebase.numer)
    }
}
