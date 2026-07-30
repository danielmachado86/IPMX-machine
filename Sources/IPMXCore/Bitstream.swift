import Foundation

public enum BitstreamError: Error, CustomStringConvertible {
    case outOfBounds
    case malformedExpGolomb
    case valueTooWide(Int)

    public var description: String {
        switch self {
        case .outOfBounds:          return "ran off the end of the bitstream"
        case .malformedExpGolomb:   return "malformed Exp-Golomb code"
        case .valueTooWide(let n):  return "cannot read or write \(n) bits at once"
        }
    }
}

/// Big-endian bit reader for H.26x RBSP data.
///
/// Parameter sets are mostly *not* byte aligned — VUI, hrd_parameters and everything after a
/// variable-length field land on arbitrary bit offsets — so anything that inspects or rewrites
/// them needs this rather than byte indexing.
public struct BitReader {
    public let data: Data
    public private(set) var bitPosition: Int = 0

    public init(_ data: Data) {
        self.data = data
    }

    public var bitCount: Int { data.count * 8 }
    public var bitsRemaining: Int { bitCount - bitPosition }

    public mutating func u(_ count: Int) throws -> UInt32 {
        guard count >= 0, count <= 32 else { throw BitstreamError.valueTooWide(count) }
        guard bitPosition + count <= bitCount else { throw BitstreamError.outOfBounds }

        var value: UInt32 = 0
        for _ in 0..<count {
            let index = data.startIndex + (bitPosition >> 3)
            let bit = (data[index] >> (7 - UInt8(bitPosition & 7))) & 1
            value = (value << 1) | UInt32(bit)
            bitPosition += 1
        }
        return value
    }

    public mutating func flag() throws -> Bool {
        try u(1) == 1
    }

    public mutating func skip(_ count: Int) throws {
        var remaining = count
        while remaining > 0 {
            let chunk = min(remaining, 32)
            _ = try u(chunk)
            remaining -= chunk
        }
    }

    /// Unsigned Exp-Golomb, ue(v).
    public mutating func ue() throws -> UInt32 {
        var leadingZeros = 0
        while try u(1) == 0 {
            leadingZeros += 1
            if leadingZeros > 31 { throw BitstreamError.malformedExpGolomb }
        }
        guard leadingZeros > 0 else { return 0 }
        let suffix = try u(leadingZeros)
        return (1 << UInt32(leadingZeros)) - 1 + suffix
    }

    /// Signed Exp-Golomb, se(v).
    public mutating func se() throws -> Int32 {
        let k = try ue()
        return k % 2 == 1 ? Int32((k + 1) / 2) : -Int32(k / 2)
    }
}

/// Big-endian bit writer, the counterpart used to rebuild a parameter set.
public struct BitWriter {
    private var bytes: [UInt8] = []
    private var bitsInLastByte = 0

    public init() {}

    public var bitPosition: Int { bytes.count * 8 - (bitsInLastByte == 0 ? 0 : 8 - bitsInLastByte) }

    public var data: Data { Data(bytes) }

    public mutating func write(bit: UInt8) {
        if bitsInLastByte == 0 {
            bytes.append(0)
            bitsInLastByte = 8
        }
        bytes[bytes.count - 1] |= (bit & 1) << UInt8(bitsInLastByte - 1)
        bitsInLastByte -= 1
    }

    public mutating func write(_ value: UInt32, bits: Int) {
        precondition(bits >= 0 && bits <= 32, "cannot write \(bits) bits at once")
        var index = bits - 1
        while index >= 0 {
            write(bit: UInt8((value >> UInt32(index)) & 1))
            index -= 1
        }
    }

    public mutating func writeUE(_ value: UInt32) {
        let code = value + 1
        let significantBits = 32 - code.leadingZeroBitCount
        for _ in 0..<(significantBits - 1) { write(bit: 0) }
        write(code, bits: significantBits)
    }

    /// Copies `count` bits verbatim out of `reader`, for the parts of a parameter set that
    /// have to survive a rewrite untouched.
    public mutating func copy(bits count: Int, from reader: inout BitReader) throws {
        var remaining = count
        while remaining > 0 {
            let chunk = min(remaining, 32)
            write(try reader.u(chunk), bits: chunk)
            remaining -= chunk
        }
    }

    /// rbsp_trailing_bits(): a stop bit followed by zeroes to the byte boundary.
    public mutating func writeRBSPTrailingBits() {
        write(bit: 1)
        while bitsInLastByte != 0 { write(bit: 0) }
    }
}

/// Emulation prevention, H.265 §7.4.2 / H.264 §7.4.1.
///
/// A NAL payload may not contain the byte sequences 00 00 00 through 00 00 03, because the
/// start code scanner would trip on them. Encoders insert a 0x03 after two zero bytes; anyone
/// reading fields at a fixed offset — or writing a NAL back out — has to undo and redo that.
public enum RBSP {
    /// Removes emulation prevention bytes: NAL payload -> RBSP.
    public static func unescape(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)

        var index = 0
        while index < bytes.count {
            if index + 2 < bytes.count,
               bytes[index] == 0x00, bytes[index + 1] == 0x00, bytes[index + 2] == 0x03 {
                out.append(0x00)
                out.append(0x00)
                index += 3
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        return Data(out)
    }

    /// Inserts emulation prevention bytes: RBSP -> NAL payload.
    public static func escape(_ data: Data) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(data.count + data.count / 32)

        var zeroRun = 0
        for byte in data {
            if zeroRun == 2 && byte <= 0x03 {
                out.append(0x03)
                zeroRun = 0
            }
            out.append(byte)
            zeroRun = byte == 0x00 ? zeroRun + 1 : 0
        }
        return Data(out)
    }
}
