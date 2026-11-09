import Foundation

/// Mirrors contracts/bootstrap-url.json, packages/protocol/src/bootstrapUrl.ts, and the Kotlin core.
public enum BootstrapUrl {
    public static let defaultPort = 8787

    /// Public hosted bootstrap. Phones save this on first start unless a different address is already stored.
    public static let defaultUrl = "wss://direct-signaling.apps.grok.bot"

    /// Bumped when the public hosted bootstrap became the default.
    public static let hostedDefaultVersion = 1

    public static func usesHttpSignal(_ url: String) -> Bool {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("wss://") || value.hasPrefix("https://")
    }

    public static func httpSignalUrl(_ url: String) -> String {
        var next = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if next.lowercased().hasPrefix("ws://") {
            next = "http://" + next.dropFirst(5)
        } else if next.lowercased().hasPrefix("wss://") {
            next = "https://" + next.dropFirst(6)
        }
        while next.hasSuffix("/") { next.removeLast() }
        return next.hasSuffix("/signal") ? next : next + "/signal"
    }

    public static func storedOrDefault(_ stored: String?) -> String {
        let value = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultUrl : value
    }

    public struct Chosen: Equatable, Sendable {
        public let url: String
        public let version: Int

        public init(url: String, version: Int) {
            self.url = url
            self.version = version
        }
    }

    public static func isLegacyLanDefault(_ input: String) -> Bool {
        guard case let .success(url) = normalize(input) else { return false }
        guard url.hasPrefix("ws://"), !url.dropFirst(5).contains("/"), url.hasSuffix(":\(defaultPort)") else { return false }
        let host = String(url.dropFirst(5).dropLast(1 + String(defaultPort).count))
        if host.hasPrefix("[") { return false }
        return privateIPv4(host)
    }

    public static func applyHostedDefault(stored: String?, version: Int) -> Chosen {
        if version >= hostedDefaultVersion {
            return Chosen(url: storedOrDefault(stored), version: version)
        }
        let current = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = current.isEmpty || isLegacyLanDefault(current) ? defaultUrl : current
        return Chosen(url: url, version: hostedDefaultVersion)
    }

    private static func privateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        let a = octets[0]
        let b = octets[1]
        return a == 10 || (a == 192 && b == 168) || (a == 172 && (16...31).contains(b)) || (a == 169 && b == 254)
    }

    public enum Failure: String, Error, CaseIterable {
        case empty, scheme, host, port, userinfo, query, loopback

        public var message: String {
            switch self {
            case .empty: return "Enter the bootstrap address, such as ws://192.168.1.20:8787."
            case .scheme: return "Use a ws:// or wss:// address."
            case .host: return "The bootstrap address needs a host name or IP address, with no spaces."
            case .port: return "The port must be a number from 1 to 65535."
            case .userinfo: return "Remove the user name and password from the address."
            case .query: return "Remove the ? or # part from the address."
            case .loopback: return "localhost on a phone is the phone itself. Use the computer's network address, the same one on both phones."
            }
        }

        public var code: String { rawValue }
    }

    private static let schemes = ["ws": "ws", "wss": "wss", "http": "ws", "https": "wss"]

    private static func matches(_ value: String, _ allowed: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { allowed.unicodeScalars.contains($0) }
    }

    public static func normalize(_ input: String) -> Result<String, Failure> {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .failure(.empty) }

        var scheme = "ws"
        var rest = value
        if let range = value.range(of: "://") {
            let candidate = String(value[..<range.lowerBound])
            let first = candidate.unicodeScalars.first
            let schemeLike = first.map { CharacterSet.letters.contains($0) } == true &&
                candidate.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "+.-".unicodeScalars.contains($0) }
            if schemeLike {
                guard let mapped = schemes[candidate.lowercased()] else { return .failure(.scheme) }
                scheme = mapped
                rest = String(value[range.upperBound...])
            }
        }
        guard !rest.contains(where: { $0.isWhitespace }) else { return .failure(.host) }
        guard !rest.contains("?"), !rest.contains("#") else { return .failure(.query) }
        let slash = rest.firstIndex(of: "/")
        let authority = slash.map { String(rest[..<$0]) } ?? rest
        var path = slash.map { String(rest[$0...]) } ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        guard !authority.contains("@") else { return .failure(.userinfo) }

        let host: String
        var port: String?
        let bracketed = authority.hasPrefix("[")
        if bracketed {
            guard let close = authority.firstIndex(of: "]") else { return .failure(.host) }
            host = String(authority[authority.index(after: authority.startIndex)..<close]).lowercased()
            let after = String(authority[authority.index(after: close)...])
            if after.hasPrefix(":") { port = String(after.dropFirst()) } else if !after.isEmpty { return .failure(.host) }
            guard matches(host, "0123456789abcdef:.") else { return .failure(.host) }
        } else {
            let parts = authority.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count <= 2 else { return .failure(.host) }
            host = parts[0].lowercased()
            if parts.count == 2 { port = parts[1] }
            guard matches(host, "abcdefghijklmnopqrstuvwxyz0123456789.-") else { return .failure(.host) }
        }

        var portNumber: Int?
        if let port {
            guard port.count <= 5, matches(port, "0123456789"), let number = Int(port), (1...65535).contains(number) else { return .failure(.port) }
            portNumber = number
        } else if scheme == "ws" {
            portNumber = defaultPort
        }

        let loopback = host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("127.") || host == "::1" || host == "0.0.0.0"
        guard !loopback else { return .failure(.loopback) }

        let shownHost = bracketed ? "[\(host)]" : host
        return .success("\(scheme)://\(shownHost)\(portNumber.map { ":\($0)" } ?? "")\(path)")
    }
}
