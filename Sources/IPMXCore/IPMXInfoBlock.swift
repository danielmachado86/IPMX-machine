import Foundation

// MARK: - Media Info Blocks

/// A block carried inside an IPMX Info Block. The container writes the type and length header;
/// conformers supply the content, already padded to a 32-bit boundary.
public protocol MediaInfoBlock {
    var type: UInt16 { get }
    func serializedContent() -> Data
}

extension MediaInfoBlock {
    /// Type, length and content. The length is the number of 32-bit words in the whole block
    /// minus one, per TR-10-2 §10.
    public func serialized() -> Data {
        var content = serializedContent()
        while content.count % 4 != 0 { content.append(0x00) }

        var out = Data()
        out.appendBigEndian(type)
        out.appendBigEndian(UInt16((content.count + 4) / 4 - 1))
        out.append(content)
        return out
    }
}

/// Media Info Block for video.
///
/// TR-10-7 §12 sets the type to 0x0005 for compressed video and says the content "shall follow
/// that of the Media Info Block for uncompressed active video as documented in TR-10-2 section
/// 10" — so the layout below is TR-10-2's 0x0001 with a different type constant.
public struct VideoMediaInfoBlock: MediaInfoBlock, Equatable, Sendable {
    public let type: UInt16 = 0x0005

    public var sampling: String              // ST 2110-20 §7.4.1, e.g. "YCbCr-4:2:0"
    public var isFloatingPoint: Bool
    public var bitDepth: UInt8               // 7 bits
    public var generalPackingMode: Bool      // ST 2110-20 §6.3.2 vs §6.3.3
    public var interlaced: Bool
    public var segmented: Bool
    public var pixelAspectWidth: UInt8       // 1 when unknown
    public var pixelAspectHeight: UInt8      // 1 when unknown
    public var range: String                 // "NARROW" when unknown
    public var colorimetry: String
    public var transferCharacteristics: String  // "SDR" when unknown
    public var width: UInt16
    public var height: UInt16
    public var rateNumerator: UInt32         // 22 bits
    public var rateDenominator: UInt32       // 10 bits
    public var measuredPixelClock: UInt64
    public var htotal: UInt16
    public var vtotal: UInt16

    public init(sampling: String,
                isFloatingPoint: Bool = false,
                bitDepth: UInt8,
                generalPackingMode: Bool = false,
                interlaced: Bool = false,
                segmented: Bool = false,
                pixelAspectWidth: UInt8 = 1,
                pixelAspectHeight: UInt8 = 1,
                range: String = "NARROW",
                colorimetry: String,
                transferCharacteristics: String = "SDR",
                width: UInt16,
                height: UInt16,
                rateNumerator: UInt32,
                rateDenominator: UInt32,
                measuredPixelClock: UInt64,
                htotal: UInt16,
                vtotal: UInt16) {
        self.sampling = sampling
        self.isFloatingPoint = isFloatingPoint
        self.bitDepth = bitDepth
        self.generalPackingMode = generalPackingMode
        self.interlaced = interlaced
        self.segmented = segmented
        self.pixelAspectWidth = pixelAspectWidth
        self.pixelAspectHeight = pixelAspectHeight
        self.range = range
        self.colorimetry = colorimetry
        self.transferCharacteristics = transferCharacteristics
        self.width = width
        self.height = height
        self.rateNumerator = rateNumerator
        self.rateDenominator = rateDenominator
        self.measuredPixelClock = measuredPixelClock
        self.htotal = htotal
        self.vtotal = vtotal
    }

    /// Builds the block for a sender whose output is not a converted baseband signal — which is
    /// every source in this project, since ScreenCaptureKit has no blanking to measure.
    /// TR-10-9 §10 pins the three fields such a sender cannot measure:
    ///   htotal = width, vtotal = height, measuredpixclk = width * height * exactframerate.
    public static func nonBaseband(sampling: String,
                                   bitDepth: UInt8,
                                   colorimetry: String,
                                   transferCharacteristics: String = "SDR",
                                   range: String = "NARROW",
                                   width: UInt16,
                                   height: UInt16,
                                   frameRate: Int) -> VideoMediaInfoBlock {
        VideoMediaInfoBlock(
            sampling: sampling,
            bitDepth: bitDepth,
            range: range,
            colorimetry: colorimetry,
            transferCharacteristics: transferCharacteristics,
            width: width,
            height: height,
            rateNumerator: UInt32(frameRate),
            rateDenominator: 1,
            measuredPixelClock: UInt64(width) * UInt64(height) * UInt64(frameRate),
            htotal: width,
            vtotal: height
        )
    }

    public func serializedContent() -> Data {
        var out = Data()
        out.append(paddedASCII(sampling, length: 16))

        // F(1) | bit depth(7) | M(1) | I(1) | S(1) | reserved(5) | PARw(8) | PARh(8)
        var writer = BitWriter()
        writer.write(isFloatingPoint ? 1 : 0, bits: 1)
        writer.write(UInt32(bitDepth), bits: 7)
        writer.write(generalPackingMode ? 1 : 0, bits: 1)
        writer.write(interlaced ? 1 : 0, bits: 1)
        writer.write(segmented ? 1 : 0, bits: 1)
        writer.write(0, bits: 5)                       // reserved
        writer.write(UInt32(pixelAspectWidth), bits: 8)
        writer.write(UInt32(pixelAspectHeight), bits: 8)
        out.append(writer.data)

        out.append(paddedASCII(range, length: 12))
        out.append(paddedASCII(colorimetry, length: 20))
        out.append(paddedASCII(transferCharacteristics, length: 16))

        out.appendBigEndian(width)
        out.appendBigEndian(height)

        // rate numerator(22) | rate denominator(10)
        var rate = BitWriter()
        rate.write(rateNumerator, bits: 22)
        rate.write(rateDenominator, bits: 10)
        out.append(rate.data)

        out.appendBigEndian(measuredPixelClock)
        out.appendBigEndian(htotal)
        out.appendBigEndian(vtotal)
        return out
    }
}

/// Media Info Block 0x000A, TR-10-15 Part 3 §16.
///
/// Only the parameters that appear in the stream's `a=fmtp` line are flagged present; the rest
/// are zero, as the spec requires. The sprop values are the **base64 characters as written in
/// the SDP**, not the raw NAL bytes.
public struct H264MediaInfoBlock: MediaInfoBlock, Equatable, Sendable {
    public let type: UInt16 = 0x000A

    public enum Field: Int {
        case profileLevelID = 0
        case packetizationMode = 1
        case spropMaxDonDiff = 2
        case spropInterleavingDepth = 3
        case spropDeintBufReq = 4
        case spropInitBufTime = 5
        case spropParameterSets = 6
        case spropLevelParameterSets = 7
        case extraBytes = 8
    }

    public var profileLevelID: UInt32?          // 3 bytes
    public var packetizationMode: UInt8?
    public var spropParameterSets: String?      // base64 text, comma separated

    public init(profileLevelID: UInt32?, packetizationMode: UInt8?, spropParameterSets: String?) {
        self.profileLevelID = profileLevelID
        self.packetizationMode = packetizationMode
        self.spropParameterSets = spropParameterSets
    }

    public init(_ parameters: H264FormatParameters) {
        self.profileLevelID = UInt32(parameters.profileLevelID, radix: 16)
        self.packetizationMode = 1                  // the packetizer is fixed to mode 1
        self.spropParameterSets = parameters.spropParameterSets
    }

    public var fieldPresentMask: UInt32 {
        var mask: UInt32 = 0
        if profileLevelID != nil { mask |= 1 << UInt32(Field.profileLevelID.rawValue) }
        if packetizationMode != nil { mask |= 1 << UInt32(Field.packetizationMode.rawValue) }
        if spropParameterSets != nil { mask |= 1 << UInt32(Field.spropParameterSets.rawValue) }
        return mask
    }

    public func serializedContent() -> Data {
        let sprop = Data((spropParameterSets ?? "").utf8)
        precondition(sprop.count <= 255, "sprop-parameter-sets does not fit in a one-byte length")

        var out = Data()
        out.appendBigEndian(fieldPresentMask)

        let profile = profileLevelID ?? 0
        out.append(UInt8((profile >> 16) & 0xFF))
        out.append(UInt8((profile >> 8) & 0xFF))
        out.append(UInt8(profile & 0xFF))
        out.append(packetizationMode ?? 0)

        out.appendBigEndian(UInt16(0))              // sprop-max-don-diff
        out.appendBigEndian(UInt16(0))              // sprop-interleaving-depth
        out.appendBigEndian(UInt32(0))              // sprop-deint-buf-req
        out.appendBigEndian(UInt32(0))              // sprop-init-buf-time

        out.append(UInt8(sprop.count))              // param-sets-N
        out.append(0)                               // l-param-sets-N
        out.append(0)                               // extra-N
        out.append(0)                               // reserved

        out.append(sprop)
        return out                                  // serialized() pads to 4 bytes
    }
}

/// Media Info Block 0x0009, TR-10-15 Part 2 §16.
public struct H265MediaInfoBlock: MediaInfoBlock, Equatable, Sendable {
    public let type: UInt16 = 0x0009

    public enum Field: Int {
        case profileSpace = 0
        case profileID = 1
        case levelID = 2
        case tierFlag = 3
        case profileCompatibilityIndicator = 4
        case interopConstraints = 5
        case spropMaxDonDiff = 6
        case txMode = 7
        case spropDepackBufBytes = 8
        case spropDepackBufNalus = 9
        case spropSpatialSegmentationIDC = 10
        case spropSubLayerID = 11
        case spropSegmentationID = 12
        case spropVPS = 13
        case spropSPS = 14
        case spropPPS = 15
        case extraBytes = 16
    }

    public var profileSpace: UInt8
    public var profileID: UInt8
    public var levelID: UInt8
    public var tierFlag: UInt8
    public var profileCompatibilityIndicator: UInt32
    public var interopConstraints: [UInt8]      // 6 bytes
    public var spropVPS: String
    public var spropSPS: String
    public var spropPPS: String

    public init(profileSpace: UInt8, profileID: UInt8, levelID: UInt8, tierFlag: UInt8,
                profileCompatibilityIndicator: UInt32, interopConstraints: [UInt8],
                spropVPS: String, spropSPS: String, spropPPS: String) {
        self.profileSpace = profileSpace
        self.profileID = profileID
        self.levelID = levelID
        self.tierFlag = tierFlag
        self.profileCompatibilityIndicator = profileCompatibilityIndicator
        self.interopConstraints = interopConstraints
        self.spropVPS = spropVPS
        self.spropSPS = spropSPS
        self.spropPPS = spropPPS
    }

    public init(_ parameters: H265FormatParameters) {
        self.profileSpace = parameters.profileSpace
        self.profileID = parameters.profileID
        self.levelID = parameters.levelID
        self.tierFlag = parameters.tierFlag
        self.profileCompatibilityIndicator =
            UInt32(parameters.profileCompatibilityIndicator, radix: 16) ?? 0
        self.interopConstraints = Self.hexBytes(parameters.interopConstraints, count: 6)
        self.spropVPS = parameters.spropVPS
        self.spropSPS = parameters.spropSPS
        self.spropPPS = parameters.spropPPS
    }

    static func hexBytes(_ text: String, count: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex, bytes.count < count {
            let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
            bytes.append(UInt8(text[index..<next], radix: 16) ?? 0)
            index = next
        }
        while bytes.count < count { bytes.append(0) }
        return bytes
    }

    /// Everything this sender knows: the six profile_tier_level fields and the three
    /// parameter sets. The optional depacketization hints are not in our fmtp, so they stay 0.
    public var fieldPresentMask: UInt32 {
        var mask: UInt32 = 0
        for field: Field in [.profileSpace, .profileID, .levelID, .tierFlag,
                             .profileCompatibilityIndicator, .interopConstraints,
                             .spropVPS, .spropSPS, .spropPPS] {
            mask |= 1 << UInt32(field.rawValue)
        }
        return mask
    }

    public func serializedContent() -> Data {
        let vps = Data(spropVPS.utf8)
        let sps = Data(spropSPS.utf8)
        let pps = Data(spropPPS.utf8)
        precondition(vps.count <= 255 && sps.count <= 255 && pps.count <= 255,
                     "a parameter set does not fit in a one-byte length")

        var out = Data()
        out.appendBigEndian(fieldPresentMask)
        out.append(profileSpace)
        out.append(profileID)
        out.append(levelID)
        out.append(tierFlag)
        out.appendBigEndian(profileCompatibilityIndicator)

        var constraints = interopConstraints
        while constraints.count < 6 { constraints.append(0) }
        out.append(contentsOf: constraints.prefix(6))   // interop-constraints 0-5

        out.appendBigEndian(UInt16(0))              // sprop-max-don-diff
        out.appendBigEndian(UInt32(0))              // tx-mode
        out.appendBigEndian(UInt32(0))              // sprop-depack-buf-bytes
        out.appendBigEndian(UInt16(0))              // sprop-depack-buf-nalus
        out.appendBigEndian(UInt16(0))              // sprop-spatial-segmentation-idc
        out.append(0)                               // sub-layer-id
        out.append(0)                               // segmentation-id
        out.appendBigEndian(UInt16(0))              // reserved

        out.append(UInt8(vps.count))
        out.append(UInt8(sps.count))
        out.append(UInt8(pps.count))
        out.append(0)                               // extra-N

        out.append(vps)
        out.append(sps)
        out.append(pps)
        return out
    }
}

/// Builds the codec-specific Media Info Block that goes with a set of format parameters.
public func makeCodecMediaInfoBlock(_ parameters: VideoFormatParameters) -> MediaInfoBlock {
    switch parameters {
    case .h264(let p): return H264MediaInfoBlock(p)
    case .h265(let p): return H265MediaInfoBlock(p)
    }
}

// MARK: - IPMX Info Block

/// The RTCP Sender Report extension defined in TR-10-1 §8.7.
///
/// Header layout: tag, length, block version, 24 reserved bits, a 64-byte `ts-refclk` string
/// and a 12-byte `mediaclk` string, followed by zero or more Media Info Blocks.
public struct IPMXInfoBlock {
    public static let tag: UInt16 = 0x5831      // the ASCII string "X1"
    public static let headerByteCount = 84      // 4 + 4 + 64 + 12

    /// "An 8-bit counter that increments whenever the content of the IPMX Info Block changes."
    public var blockVersion: UInt8
    public var timestampReferenceClock: String  // the a=ts-refclk value, e.g. "localmac"
    public var mediaClock: String               // the a=mediaclk value, e.g. "direct=0"
    public var mediaInfoBlocks: [MediaInfoBlock]

    public init(blockVersion: UInt8,
                timestampReferenceClock: String,
                mediaClock: String,
                mediaInfoBlocks: [MediaInfoBlock]) {
        self.blockVersion = blockVersion
        self.timestampReferenceClock = timestampReferenceClock
        self.mediaClock = mediaClock
        self.mediaInfoBlocks = mediaInfoBlocks
    }

    /// Everything except the version byte itself, so a sender can tell whether the content
    /// changed and therefore whether `blockVersion` has to be incremented.
    public func contentFingerprint() -> Data {
        var out = serialized()
        out.remove(at: out.startIndex + 4)          // the block version byte
        return out
    }

    public func serialized() -> Data {
        var body = Data()
        body.append(blockVersion)
        body.append(contentsOf: [0x00, 0x00, 0x00])         // reserved, 24 bits
        body.append(paddedASCII(timestampReferenceClock, length: 64))
        body.append(paddedASCII(mediaClock, length: 12))
        for block in mediaInfoBlocks {
            body.append(block.serialized())
        }
        while body.count % 4 != 0 { body.append(0x00) }

        var out = Data()
        out.appendBigEndian(IPMXInfoBlock.tag)
        // "the number of 32-bit words in the IPMX Info Block minus one", counting the header.
        out.appendBigEndian(UInt16((body.count + 4) / 4 - 1))
        out.append(body)
        return out
    }
}

// MARK: - Helpers

/// ASCII, truncated or zero-padded to a fixed width. Every string field in an Info Block is
/// fixed width and 0x00 padded.
func paddedASCII(_ text: String, length: Int) -> Data {
    var out = Data(text.utf8.prefix(length))
    while out.count < length { out.append(0x00) }
    return out
}

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt32) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt64) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
