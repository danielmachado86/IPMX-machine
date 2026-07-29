import Foundation

/// Tiny `--key value` parser. Deliberately dependency-free: pulling in
/// swift-argument-parser would make the build require network access, which is a
/// bad trade for a handful of flags.
public struct CommandLineOptions {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    public init(_ arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else { index += 1; continue }
            let key = String(argument.dropFirst(2))

            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                values[key] = arguments[index + 1]
                index += 2
            } else {
                flags.insert(key)
                index += 1
            }
        }
    }

    public func string(_ key: String, default fallback: String) -> String {
        values[key] ?? fallback
    }

    public func int(_ key: String, default fallback: Int) -> Int {
        values[key].flatMap(Int.init) ?? fallback
    }

    public func uint16(_ key: String, default fallback: UInt16) -> UInt16 {
        values[key].flatMap(UInt16.init) ?? fallback
    }

    public func flag(_ key: String) -> Bool {
        flags.contains(key) || values[key] == "true"
    }

    public func has(_ key: String) -> Bool {
        values[key] != nil || flags.contains(key)
    }

    public func optionalString(_ key: String) -> String? {
        values[key]
    }
}

public enum Log {
    nonisolated(unsafe) public static var verbose = false

    public static func info(_ message: String) {
        FileHandle.standardError.write("[ipmx] \(message)\n".data(using: .utf8)!)
    }

    public static func debug(_ message: String) {
        guard verbose else { return }
        FileHandle.standardError.write("[ipmx] \(message)\n".data(using: .utf8)!)
    }

    public static func error(_ message: String) {
        FileHandle.standardError.write("[ipmx] error: \(message)\n".data(using: .utf8)!)
    }
}
