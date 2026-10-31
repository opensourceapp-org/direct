import Foundation

/// Minimal JSON with ordered objects. Bundles and envelopes are signed or compared as exact
/// strings, so field order and escaping must match `JSON.stringify` in the TypeScript packages.
public indirect enum JSON: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    public static func == (lhs: JSON, rhs: JSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            guard a.count == b.count else { return false }
            let right = Dictionary(b, uniquingKeysWith: { first, _ in first })
            return a.allSatisfy { key, value in right[key] == value }
        default: return false
        }
    }

    public subscript(key: String) -> JSON? {
        guard case let .object(pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }

    public var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    /// Integers only; JSON numbers with a fraction or beyond 2^53 return nil.
    public var int64: Int64? {
        guard case let .number(value) = self, value.rounded() == value, abs(value) <= 9_007_199_254_740_992 else { return nil }
        return Int64(value)
    }

    public var array: [JSON]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var objectPairs: [(String, JSON)]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public static func int(_ value: Int64) -> JSON { .number(Double(value)) }
    public static func optional(_ value: String?) -> JSON { value.map(JSON.string) ?? .null }

    public func serialized() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case let .bool(value): out += value ? "true" : "false"
        case let .number(value):
            if value.rounded() == value, abs(value) < 1e15 { out += String(Int64(value)) } else { out += String(value) }
        case let .string(value): JSON.quote(value, into: &out)
        case let .array(items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case let .object(pairs):
            out += "{"
            for (index, pair) in pairs.enumerated() {
                if index > 0 { out += "," }
                JSON.quote(pair.0, into: &out)
                out += ":"
                pair.1.write(into: &out)
            }
            out += "}"
        }
    }

    private static func quote(_ value: String, into out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    public static func parse(_ text: String) -> JSON? {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        parser.skipSpace()
        guard let value = parser.value(depth: 0) else { return nil }
        parser.skipSpace()
        return parser.index == parser.scalars.count ? value : nil
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        mutating func skipSpace() {
            while index < scalars.count, [" ", "\n", "\r", "\t"].contains(scalars[index]) { index += 1 }
        }

        mutating func value(depth: Int) -> JSON? {
            guard depth < 64, index < scalars.count else { return nil }
            switch scalars[index] {
            case "{": return object(depth: depth)
            case "[": return array(depth: depth)
            case "\"": return string().map(JSON.string)
            case "t": return literal("true", .bool(true))
            case "f": return literal("false", .bool(false))
            case "n": return literal("null", .null)
            default: return number()
            }
        }

        mutating func literal(_ word: String, _ result: JSON) -> JSON? {
            let chars = Array(word.unicodeScalars)
            guard index + chars.count <= scalars.count, Array(scalars[index..<index + chars.count]) == chars else { return nil }
            index += chars.count
            return result
        }

        mutating func number() -> JSON? {
            let start = index
            while index < scalars.count, "+-0123456789.eE".unicodeScalars.contains(scalars[index]) { index += 1 }
            guard index > start else { return nil }
            var text = ""
            text.unicodeScalars.append(contentsOf: scalars[start..<index])
            return Double(text).map(JSON.number)
        }

        mutating func string() -> String? {
            index += 1
            var out = String.UnicodeScalarView()
            var pendingHigh: UInt32?
            while index < scalars.count {
                let scalar = scalars[index]
                index += 1
                if scalar == "\"" { return String(out) }
                if scalar.value < 0x20 { return nil }
                guard scalar == "\\" else {
                    out.append(scalar)
                    continue
                }
                guard index < scalars.count else { return nil }
                let escape = scalars[index]
                index += 1
                switch escape {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    guard index + 4 <= scalars.count else { return nil }
                    var hex = ""
                    hex.unicodeScalars.append(contentsOf: scalars[index..<index + 4])
                    index += 4
                    guard let code = UInt32(hex, radix: 16) else { return nil }
                    if (0xD800...0xDBFF).contains(code) {
                        pendingHigh = code
                        continue
                    }
                    if (0xDC00...0xDFFF).contains(code), let high = pendingHigh {
                        pendingHigh = nil
                        guard let combined = Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (code - 0xDC00)) else { return nil }
                        out.append(combined)
                        continue
                    }
                    guard let decoded = Unicode.Scalar(code) else { return nil }
                    out.append(decoded)
                default: return nil
                }
            }
            return nil
        }

        mutating func array(depth: Int) -> JSON? {
            index += 1
            var items: [JSON] = []
            skipSpace()
            if index < scalars.count, scalars[index] == "]" {
                index += 1
                return .array(items)
            }
            while true {
                skipSpace()
                guard let item = value(depth: depth + 1) else { return nil }
                items.append(item)
                skipSpace()
                guard index < scalars.count else { return nil }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "]" { index += 1; return .array(items) }
                return nil
            }
        }

        mutating func object(depth: Int) -> JSON? {
            index += 1
            var pairs: [(String, JSON)] = []
            skipSpace()
            if index < scalars.count, scalars[index] == "}" {
                index += 1
                return .object(pairs)
            }
            while true {
                skipSpace()
                guard index < scalars.count, scalars[index] == "\"", let key = string() else { return nil }
                skipSpace()
                guard index < scalars.count, scalars[index] == ":" else { return nil }
                index += 1
                skipSpace()
                guard let item = value(depth: depth + 1) else { return nil }
                pairs.append((key, item))
                skipSpace()
                guard index < scalars.count else { return nil }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "}" { index += 1; return .object(pairs) }
                return nil
            }
        }
    }
}
