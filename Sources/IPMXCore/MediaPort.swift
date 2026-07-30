import Foundation

/// TR-10-7 §7 constrains the UDP destination port of an IPMX media stream:
///
///   "All IPMX Media streams shall have a UDP destination port value that is even,
///    and that is greater than 1024."
///   "All IPMX Media streams should have a UDP destination port value that is greater than 5000."
///
/// The first is a *shall*, so it is rejected rather than warned about. The second is a
/// *should*, so it warns and continues.
///
/// Even matters for a concrete reason: RTCP goes to the port immediately above the media
/// port (TR-10-1 §8.7), so an odd media port would put RTCP on an even port and collide with
/// the next stream's media. Phase 2 depends on this holding.
public enum MediaPort {
    public enum ValidationError: Error, CustomStringConvertible {
        case odd(UInt16)
        case tooLow(UInt16)

        public var description: String {
            switch self {
            case .odd(let port):
                return "TR-10-7 §7: the UDP destination port shall be even, but \(port) is odd. "
                     + "RTCP uses port+1, so an odd media port collides with the next stream."
            case .tooLow(let port):
                return "TR-10-7 §7: the UDP destination port shall be greater than 1024, got \(port)."
            }
        }
    }

    /// Throws when a *shall* is violated. Returns any *should* advisories for the caller to log.
    @discardableResult
    public static func validate(_ port: UInt16) throws -> [String] {
        if port <= 1024 { throw ValidationError.tooLow(port) }
        if port % 2 != 0 { throw ValidationError.odd(port) }

        var advisories: [String] = []
        if port <= 5000 {
            advisories.append("TR-10-7 §7 recommends a UDP destination port above 5000, got \(port)")
        }
        return advisories
    }

    public static func isValid(_ port: UInt16) -> Bool {
        (try? validate(port)) != nil
    }
}
