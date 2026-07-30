import Foundation

/// How a Sender's Media Clock relates to its Internal Clock, per TR-10-1 §10.5.
///
/// > If the Media Clock is directly derived from the Internal Clock, the direct reference shall
/// > be used and the offset of '0' shall be included. For example: `a=mediaclk:direct=0`
/// >
/// > If the Media Clock is asynchronous with respect to the Internal Clock, for example if
/// > Async Media is present at the input of a Sender, the following form shall be used:
/// > `a=mediaclk:sender`
///
/// This is not cosmetic. A synthetic source — screen capture, a pattern generator — is timed by
/// the sender itself, so a receiver can rely on the reference clock. A capture card is timed by
/// whatever is plugged into the HDMI or SDI input, and that clock is free-running with respect
/// to ours; declaring `direct=0` there tells a receiver it can lock to a relationship that does
/// not exist.
///
/// The value appears in two places that have to agree: the `a=mediaclk` attribute of the SDP
/// and the 12-byte mediaclk string of the IPMX Info Block (TR-10-1 §8.7).
public enum MediaClockRelationship: Sendable, Equatable {
    /// Derived from the Internal Clock, with the offset the spec requires.
    case direct(offset: UInt32 = 0)
    /// Asynchronous to the Internal Clock: Async Media at the input of the Sender.
    case sender

    public var sdpValue: String {
        switch self {
        case .direct(let offset): return "direct=\(offset)"
        case .sender:             return "sender"
        }
    }

    /// True when the media timing comes from outside and cannot be assumed constant.
    public var isAsynchronous: Bool {
        if case .sender = self { return true }
        return false
    }

    public init?(sdpValue: String) {
        let trimmed = sdpValue.trimmingCharacters(in: .whitespaces)
        if trimmed == "sender" {
            self = .sender
        } else if trimmed.hasPrefix("direct="), let offset = UInt32(trimmed.dropFirst("direct=".count)) {
            self = .direct(offset: offset)
        } else {
            return nil
        }
    }
}
