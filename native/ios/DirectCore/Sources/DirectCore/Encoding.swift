import Crypto
import Foundation

public enum Encoding {
    private static let crockfordAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func utf8(_ value: String) -> Data { Data(value.utf8) }

    public static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    public static func base64Url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func fromBase64Url(_ value: String) -> Data? {
        let trimmed = value.hasSuffix("=") ? String(value.prefix { $0 != "=" }) : value
        guard trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var base64 = trimmed.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }

    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func fromHex(_ value: String) -> Data? {
        let chars = Array(value)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }

    public static func sha256(_ parts: Data...) -> Data {
        var hasher = SHA256()
        parts.forEach { hasher.update(data: $0) }
        return Data(hasher.finalize())
    }

    public static func crockford(_ data: Data) -> String {
        var out = ""
        var bits = 0
        var value = 0
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(crockfordAlphabet[(value >> bits) & 31])
            }
            value &= (1 << bits) - 1
        }
        if bits > 0 { out.append(crockfordAlphabet[(value << (5 - bits)) & 31]) }
        return out
    }

    public static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    public static func newId(_ prefix: String) -> String { "\(prefix)_\(hex(randomBytes(16)))" }

    public static func newDeviceId() -> String { "dev_\(crockford(randomBytes(10)))" }
}

extension Data {
    mutating func wipe() {
        resetBytes(in: startIndex..<endIndex)
    }
}
