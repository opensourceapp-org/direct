import Foundation

/// BIP-39 English, 24 words for the 32-byte identity seed.
public enum Mnemonic {
    private static let words: [String] = {
        guard let url = Bundle.module.url(forResource: "bip39-english", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { fatalError("BIP-39 wordlist is missing from the build.") }
        let list = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        precondition(list.count == 2048, "BIP-39 wordlist must have 2048 words.")
        return list
    }()

    private static let index: [String: Int] = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, $0) })

    public static func fromSeed(_ seed: Data) throws -> String {
        let bytes = [UInt8](seed)
        guard bytes.count == 32 else { throw IdentityError("Identity seed must be 32 bytes.") }
        let checksum = Encoding.sha256(seed)[0]
        var bits = [Bool](repeating: false, count: 264)
        for i in 0..<256 { bits[i] = (bytes[i / 8] >> (7 - i % 8)) & 1 == 1 }
        for i in 0..<8 { bits[256 + i] = (checksum >> (7 - i)) & 1 == 1 }
        return (0..<24).map { group -> String in
            var value = 0
            for bit in 0..<11 { value = (value << 1) | (bits[group * 11 + bit] ? 1 : 0) }
            return words[value]
        }.joined(separator: " ")
    }

    public static func toSeed(_ phrase: String) throws -> Data {
        let parts = phrase.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count == 24 else { throw IdentityError("Recovery phrase is not valid.") }
        var bits = [Bool](repeating: false, count: 264)
        for (group, word) in parts.enumerated() {
            guard let value = index[word] else { throw IdentityError("Recovery phrase is not valid.") }
            for bit in 0..<11 { bits[group * 11 + bit] = (value >> (10 - bit)) & 1 == 1 }
        }
        var seed = [UInt8](repeating: 0, count: 32)
        for i in 0..<256 where bits[i] { seed[i / 8] |= 1 << (7 - i % 8) }
        var checksum: UInt8 = 0
        for i in 0..<8 { checksum = (checksum << 1) | (bits[256 + i] ? 1 : 0) }
        guard checksum == Encoding.sha256(Data(seed))[0] else { throw IdentityError("Recovery phrase is not valid.") }
        return Data(seed)
    }
}
