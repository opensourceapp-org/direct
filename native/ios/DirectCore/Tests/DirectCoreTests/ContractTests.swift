import XCTest
@testable import DirectCore

final class ContractTests: XCTestCase {
    private let vectors = Contracts.json("vectors.json")

    private func s(_ json: JSON?, _ key: String) -> String { json![key]!.string! }

    /// Everything except agreementSig, which Apple CryptoKit randomizes; the signature must still verify.
    private func assertSameBundle(_ expected: String, _ actual: String, file: StaticString = #filePath, line: UInt = #line) throws {
        var left = JSON.parse(expected)!.objectPairs!
        var right = JSON.parse(actual)!.objectPairs!
        XCTAssertEqual(left.map(\.0), right.map(\.0), "field order", file: file, line: line)
        left.removeAll { $0.0 == "agreementSig" }
        right.removeAll { $0.0 == "agreementSig" }
        XCTAssertEqual(JSON.object(left).serialized(), JSON.object(right).serialized(), file: file, line: line)
        XCTAssertNoThrow(try Bundles.parse(actual), file: file, line: line)
        #if os(Linux)
        XCTAssertEqual(expected, actual, "BoringSSL Ed25519 is deterministic, so Linux reproduces the exact bytes", file: file, line: line)
        #endif
    }

    func testIdentityFieldsAndBundleBytesMatchTheTypeScriptReference() throws {
        for who in ["ada", "bo"] {
            let vector = vectors[who]
            let keys = try IdentityKeys.fromSeed(Encoding.fromHex(s(vector, "seedHex"))!)
            XCTAssertEqual(s(vector, "signingPublic"), Encoding.base64Url(keys.signingPublic))
            XCTAssertEqual(s(vector, "agreementSecret"), Encoding.base64Url(keys.agreementSecret))
            XCTAssertEqual(s(vector, "agreementPublic"), Encoding.base64Url(keys.agreementPublic))
            XCTAssertEqual(s(vector, "directId"), keys.directId)
            let bundle = try Bundles.create(keys: keys, displayName: s(vector, "name"), deviceId: s(vector, "deviceId"))
            XCTAssertEqual(s(vector, "did"), bundle.did)
            XCTAssertEqual(s(vector, "fingerprint"), bundle.fingerprint)
            try assertSameBundle(s(vector, "bundle"), bundle.encode())
            XCTAssertEqual(s(vector, "mnemonic"), try Mnemonic.fromSeed(keys.seed))
            XCTAssertEqual(s(vector, "seedHex"), Encoding.hex(try Mnemonic.toSeed(s(vector, "mnemonic"))))
            XCTAssertEqual(s(vector, "directId"), try Bundles.parse(s(vector, "bundle")).directId)
        }
        let escaped = vectors["escapedName"]
        let ada = try IdentityKeys.fromSeed(Encoding.fromHex(s(vectors["ada"], "seedHex"))!)
        try assertSameBundle(s(escaped, "bundle"), try Bundles.create(keys: ada, displayName: s(escaped, "name"), deviceId: "dev_0000000000000ADA").encode())
        XCTAssertEqual(s(escaped, "name"), try Bundles.parse(s(escaped, "bundle")).name)
    }

    func testATamperedBundleOrPhraseIsRejected() {
        let bundle = s(vectors["ada"], "bundle")
        XCTAssertThrowsError(try Bundles.parse(bundle.replacingOccurrences(of: "\"Ada\"", with: "\"Eve\"")))
        let phrase = s(vectors["ada"], "mnemonic")
        XCTAssertThrowsError(try Mnemonic.toSeed(phrase.replacingOccurrences(of: "abandon", with: "ability")))
    }

    func testSealedValuesAndEnvelopesFromTypeScriptOpenHere() throws {
        let bo = try IdentityKeys.fromSeed(Encoding.fromHex(s(vectors["bo"], "seedHex"))!)
        let ada = try IdentityKeys.fromSeed(Encoding.fromHex(s(vectors["ada"], "seedHex"))!)
        let seal = vectors["seal"]
        let opened = try Seal.open(agreementSecret: bo.agreementSecret, payload: Encoding.fromBase64Url(s(seal, "sealed"))!, aad: Encoding.utf8(s(seal, "aad")))
        XCTAssertEqual(s(seal, "plaintext"), Encoding.text(opened))

        let envelopes = vectors["envelopes"]
        let now = envelopes!["now"]!.int64!
        let message = envelopes!["message"]
        let decoded = try Envelopes.decode(Encoding.utf8(s(message, "json")), senderSigningPublic: ada.signingPublic, now: now)
        XCTAssertEqual(.message, decoded.type)
        XCTAssertEqual(s(message, "body"), Encoding.text(try Envelopes.open(recipient: bo, envelope: decoded)))
        XCTAssertEqual(s(message, "json"), decoded.encode())
        for kind in ["ack", "read"] {
            let receipt = envelopes![kind]
            let envelope = try Envelopes.decode(Encoding.utf8(s(receipt, "json")), senderSigningPublic: bo.signingPublic, now: now)
            XCTAssertEqual(s(receipt, "receipt"), Encoding.text(try Envelopes.open(recipient: ada, envelope: envelope)))
        }
        XCTAssertThrowsError(try Envelopes.decode(Encoding.utf8(s(message, "json")), senderSigningPublic: bo.signingPublic, now: now))
    }

    func testAnEnvelopeSealedHereOpensWithTheSameRules() throws {
        let ada = IdentityKeys.generate()
        let bo = IdentityKeys.generate()
        let envelope = try Envelopes.seal(
            sender: ada, deviceId: "dev_1", recipientId: bo.directId, recipientAgreementPublic: bo.agreementPublic,
            id: "msg_1", type: .message, plaintext: Encoding.utf8("hi"), createdAt: 1_000, ttlMs: 60_000
        )
        let decoded = try Envelopes.decode(Encoding.utf8(envelope.encode()), senderSigningPublic: ada.signingPublic, now: 2_000)
        XCTAssertEqual("hi", Encoding.text(try Envelopes.open(recipient: bo, envelope: decoded)))
        XCTAssertThrowsError(try Envelopes.decode(Encoding.utf8(envelope.encode()), senderSigningPublic: ada.signingPublic, now: 200_000))
    }

    func testBackoffBoundsMatch() {
        for row in vectors["backoff"]!.array! {
            let attempt = Int(row["attempt"]!.int64!)
            XCTAssertEqual(row["min"]!.int64!, Backoff.delayMs(attempt: attempt, random: { 0 }))
            XCTAssertEqual(row["max"]!.int64!, Backoff.delayMs(attempt: attempt, random: { 1 }))
        }
    }

    func testBootstrapAddressesNormalizeLikeTheContract() {
        let contract = Contracts.json("bootstrap-url.json")
        XCTAssertEqual(contract["hostedDefault"]?.string, BootstrapUrl.defaultUrl)
        XCTAssertEqual(BootstrapUrl.defaultUrl, BootstrapUrl.storedOrDefault(nil))
        XCTAssertEqual(BootstrapUrl.Chosen(url: BootstrapUrl.defaultUrl, version: BootstrapUrl.hostedDefaultVersion), BootstrapUrl.applyHostedDefault(stored: nil, version: 0))
        XCTAssertEqual(BootstrapUrl.Chosen(url: BootstrapUrl.defaultUrl, version: BootstrapUrl.hostedDefaultVersion), BootstrapUrl.applyHostedDefault(stored: "ws://192.168.1.121:8787", version: 0))
        XCTAssertEqual(BootstrapUrl.Chosen(url: BootstrapUrl.defaultUrl, version: BootstrapUrl.hostedDefaultVersion), BootstrapUrl.applyHostedDefault(stored: "192.168.1.121", version: 0))
        XCTAssertEqual(BootstrapUrl.Chosen(url: "ws://192.168.1.121:8787", version: BootstrapUrl.hostedDefaultVersion), BootstrapUrl.applyHostedDefault(stored: "ws://192.168.1.121:8787", version: BootstrapUrl.hostedDefaultVersion))
        XCTAssertEqual(BootstrapUrl.Chosen(url: "wss://signals.example.com", version: BootstrapUrl.hostedDefaultVersion), BootstrapUrl.applyHostedDefault(stored: "wss://signals.example.com", version: 0))
        for row in contract["cases"]!.array! {
            let input = row["input"]!.string!
            switch BootstrapUrl.normalize(input) {
            case let .success(url): XCTAssertEqual(row["url"]?.string, url, input)
            case let .failure(error): XCTAssertEqual(row["error"]?.string, error.code, input)
            }
        }
    }

    func testSignalingFramesEncodeAndDecodeExactlyAsTheContract() {
        let contract = Contracts.json("signaling.json")
        for section in ["clientToHub", "hubToClient"] {
            for (name, example) in contract[section]!.objectPairs! {
                guard let frame = SignalCodec.decode(example.serialized()) else {
                    XCTFail("\(section).\(name) did not decode")
                    continue
                }
                XCTAssertEqual(example, JSON.parse(SignalCodec.encode(frame)), name)
            }
        }
        XCTAssertEqual(.presence(directId: "dir_ABCDEFGHJKMNPQRS", online: true), SignalCodec.decode(contract["hubToClient"]!["presenceOnline"]!.serialized()))
        for forbidden in contract["forbidden"]!.array! {
            XCTAssertNil(SignalCodec.decode(forbidden.serialized()), forbidden.serialized())
        }
    }

    func testJsonEscapingMatchesJavaScript() {
        XCTAssertEqual(#""a\"b\\c\nd\u0001é✓/""#, JSON.string("a\"b\\c\nd\u{01}é✓/").serialized())
        XCTAssertEqual(JSON.string("😀"), JSON.parse(#""\ud83d\ude00""#))
        XCTAssertNil(JSON.parse("{\"a\":1,}"))
    }
}
